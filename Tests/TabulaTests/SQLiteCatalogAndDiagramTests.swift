import XCTest

@testable import Tabula
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQLite

/// SQLite's catalog (keys, metrics, triggers), and the diagram and routine tabs built on it.
@MainActor
final class SQLiteCatalogAndDiagramTests: XCTestCase {
    private var path = ""
    private var driver: SQLiteDriver?

    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    override func setUp() async throws {
        path =
            FileManager.default.temporaryDirectory.appendingPathComponent("tabula-cat-\(UUID().uuidString).sqlite")
            .path
        let driver = try SQLiteDriver(path: path)
        _ = try await driver.executeScript(
            """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers, note TEXT);
            CREATE TABLE lines (id INTEGER PRIMARY KEY, order_id INTEGER, sku TEXT, qty INTEGER,
              FOREIGN KEY (order_id, sku) REFERENCES orders (id, note));
            CREATE TABLE settings (k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE audit (at TEXT, what TEXT);
            INSERT INTO customers (name) VALUES ('An'), ('Bình');
            INSERT INTO orders (customer_id) VALUES (1);
            CREATE TRIGGER orders_audit AFTER INSERT ON orders BEGIN INSERT INTO audit VALUES ('now', 'order'); END;
            """
        )
        self.driver = driver
    }

    override func tearDown() async throws {
        await driver?.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    func testForeignKeysIncludingImplicitAndCompositeOnes() async throws {
        let keys = try await XCTUnwrap(driver).foreignKeys(in: "main")
        let byTable = Dictionary(grouping: keys, by: \.table.name)
        let orders = try XCTUnwrap(byTable["orders"]?.first)
        XCTAssertEqual(orders.columns, ["customer_id"])
        XCTAssertEqual(orders.referencedTable.name, "customers")
        XCTAssertEqual(orders.referencedColumns, [], "a key to the primary key names no column")
        let lines = try XCTUnwrap(byTable["lines"]?.first)
        XCTAssertEqual(lines.columns, ["order_id", "sku"])
        XCTAssertEqual(lines.referencedColumns, ["id", "note"])
        XCTAssertNil(byTable["settings"])
    }

    func testMetricsCountRowsPerTable() async throws {
        let sample = try await XCTUnwrap(driver).metrics(schema: "main")
        XCTAssertEqual(sample.tables.first?.name, "customers", "most rows first")
        XCTAssertEqual(sample.tables.first?.rows, 2)
        let labels = sample.groups.flatMap(\.items).map(\.label)
        XCTAssertTrue(labels.contains("File size") && labels.contains("Journal mode"), "\(labels)")
    }

    func testTriggersAreListedReadAndReplaced() async throws {
        let driver = try XCTUnwrap(driver)
        let routines = try await XCTUnwrap(driver.routineCatalog).routines(in: "main", on: driver)
        let trigger = try XCTUnwrap(routines.first)
        XCTAssertEqual(trigger.name, "orders_audit")
        XCTAssertEqual(trigger.table, "orders")
        let definition = try await driver.definition(of: trigger)
        XCTAssertTrue(definition.hasPrefix("CREATE TRIGGER orders_audit AFTER INSERT ON orders"), definition)

        // A replacement that fails leaves the trigger as it was.
        do {
            try await driver.replace(trigger, original: definition, with: "CREATE TRIGGER orders_audit oops;")
            XCTFail("expected the broken definition to be refused")
        } catch {}
        let kept = try await driver.definition(of: trigger)
        XCTAssertEqual(kept, definition)
    }

    func testDiagramPutsReferencedTablesLeftAndLonelyOnesBelow() async throws {
        let model = DiagramModel(schema: "main", driver: try XCTUnwrap(driver))
        await model.load()
        XCTAssertNil(model.error)
        let position = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.table.name, $0.position) })
        let customers = try XCTUnwrap(position["customers"])
        let orders = try XCTUnwrap(position["orders"])
        let lines = try XCTUnwrap(position["lines"])
        XCTAssertLessThan(customers.x, orders.x)
        XCTAssertLessThan(orders.x, lines.x)
        let settings = try XCTUnwrap(position["settings"])
        XCTAssertGreaterThan(settings.y, max(customers.y, orders.y, lines.y), "unrelated tables go below")

        model.zoom = 10
        XCTAssertEqual(model.zoom, DiagramModel.maxZoom)
        model.zoom = 0
        XCTAssertEqual(model.zoom, DiagramModel.minZoom)

        model.showAllColumns = false
        let ordersNode = try XCTUnwrap(model.nodes.first { $0.table.name == "orders" })
        XCTAssertEqual(model.visibleColumns(ordersNode).map(\.name), ["id", "customer_id"], "keys only")
        model.move(ordersNode.id, to: CGPoint(x: -5, y: 40))
        XCTAssertEqual(model.nodes.first { $0.table.name == "orders" }?.position, CGPoint(x: 0, y: 40))
    }

    func testDiagramOfAnEmptySchemaSaysSo() async throws {
        _ = try await XCTUnwrap(driver).execute("ATTACH DATABASE ':memory:' AS spare")
        let model = DiagramModel(schema: "spare", driver: try XCTUnwrap(driver))
        await model.load()
        XCTAssertEqual(model.error, "No tables in spare.")
        XCTAssertEqual(model.canvasSize.width, DiagramModel.emptyCanvas.width + DiagramModel.canvasMargin)
    }

    func testRoutineTabSavesAndReverts() async throws {
        try TestDataDirectory.check()
        let workspace = WorkspaceModel(config: ConnectionConfig(kind: .sqlite, filePath: path), password: nil)
        await workspace.connect()
        defer { Task { await workspace.disconnect() } }
        await workspace.loadRoutines()
        let trigger = try XCTUnwrap(workspace.routines.first)
        let tab = RoutineTabModel(routine: trigger, driver: try XCTUnwrap(workspace.driver), workspace: workspace)
        await tab.load()
        XCTAssertFalse(tab.hasChanges)
        let original = tab.text

        tab.text = original.replacingOccurrences(of: "'order'", with: "'new order'")
        XCTAssertTrue(tab.hasChanges)
        tab.revert()
        XCTAssertEqual(tab.text, original)

        tab.text = original.replacingOccurrences(of: "'order'", with: "'new order'")
        await tab.save()
        XCTAssertNil(tab.error)
        XCTAssertEqual(tab.notice, "Saved.")
        XCTAssertFalse(tab.hasChanges, "the tab now holds what the database has")
        XCTAssertTrue(tab.text.contains("'new order'"))

        // A new trigger from the template is found again after saving.
        let template = try XCTUnwrap(workspace.driver?.routineCatalog)
            .template(for: .trigger, schema: "main", table: "customers")
        let new = RoutineTabModel(
            newKind: .trigger,
            template: template.replacingOccurrences(of: "new_trigger", with: "customers_touch"),
            driver: try XCTUnwrap(workspace.driver),
            workspace: workspace
        )
        XCTAssertEqual(new.title, "New trigger")
        await new.save()
        XCTAssertNil(new.error)
        XCTAssertEqual(new.routine?.name, "customers_touch")
        XCTAssertEqual(workspace.routines.map(\.name).sorted(), ["customers_touch", "orders_audit"])
    }
}
