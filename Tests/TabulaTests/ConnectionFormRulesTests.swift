import XCTest

@testable import Tabula
@testable import TabulaFoundation

final class ConnectionFormRulesTests: XCTestCase {
    private func form() -> ConnectionConfig {
        var config = ConnectionConfig(kind: .postgres, host: "db.internal", port: 5432, user: "app", database: "shop")
        config.name = "Shop"
        config.tag = .production
        config.connectTimeout = 30
        config.ssh = SSHConfig(host: "bastion", user: "me")
        return config
    }

    func testPastingKeepsTheConnectionsOwnSettings() throws {
        let current = form()
        let pasted = try XCTUnwrap(
            ConnectionFormRules.pasted(
                "postgresql://reader:secret@db.internal:5432/sales",
                over: current,
                password: "saved",
                oldHost: "db.internal"
            )
        )
        XCTAssertEqual(pasted.config.id, current.id)
        XCTAssertEqual(pasted.config.name, "Shop")
        XCTAssertEqual(pasted.config.tag, .production)
        XCTAssertEqual(pasted.config.connectTimeout, 30)
        XCTAssertEqual(pasted.config.ssh?.host, "bastion")
        XCTAssertEqual(pasted.config.user, "reader")
        XCTAssertEqual(pasted.config.database, "sales")
        XCTAssertEqual(pasted.password, "secret", "the URL's password wins")
        XCTAssertFalse(pasted.changedKind)
    }

    func testTheSavedPasswordStaysOnlyWithItsServer() throws {
        let current = form()
        let same = try XCTUnwrap(
            ConnectionFormRules.pasted(
                "postgresql://app@db.internal/other",
                over: current,
                password: "saved",
                oldHost: "db.internal"
            )
        )
        XCTAssertEqual(same.password, "saved", "same server, another database")
        let otherHost = try XCTUnwrap(
            ConnectionFormRules.pasted(
                "postgresql://app@evil.example/shop",
                over: current,
                password: "saved",
                oldHost: "db.internal"
            )
        )
        XCTAssertEqual(otherHost.password, "", "never sent to another server")
        let otherPort = try XCTUnwrap(
            ConnectionFormRules.pasted(
                "postgresql://app@db.internal:5433/shop",
                over: current,
                password: "saved",
                oldHost: "db.internal"
            )
        )
        XCTAssertEqual(otherPort.password, "", "another port on the same host is another server")
        let otherKind = try XCTUnwrap(
            ConnectionFormRules.pasted(
                "mysql://app@db.internal/shop",
                over: current,
                password: "saved",
                oldHost: "db.internal"
            )
        )
        XCTAssertEqual(otherKind.password, "")
        XCTAssertTrue(otherKind.changedKind)
        XCTAssertEqual(otherKind.config.ssh?.host, "bastion", "MySQL can use the SSH server too")
        let redis = try XCTUnwrap(
            ConnectionFormRules.pasted(
                "redis://db.internal:6379/2",
                over: current,
                password: "saved",
                oldHost: "db.internal"
            )
        )
        XCTAssertNil(redis.config.ssh, "kinds without SSH tunnels drop it")
    }

    func testTextThatIsntAConnectionStringChangesNothing() {
        XCTAssertNil(ConnectionFormRules.pasted("db.internal", over: form(), password: "saved", oldHost: "db"))
    }

    func testWhatEachKindNeedsToConnect() {
        XCTAssertFalse(ConnectionFormRules.isValid(ConnectionConfig(kind: .sqlite)))
        XCTAssertTrue(ConnectionFormRules.isValid(ConnectionConfig(kind: .sqlite, filePath: "/tmp/a.sqlite")))
        XCTAssertFalse(ConnectionFormRules.isValid(ConnectionConfig(kind: .postgres, port: 5432)), "needs a user")
        XCTAssertFalse(ConnectionFormRules.isValid(ConnectionConfig(kind: .mysql, port: 70000, user: "u")))
        var tunnel = ConnectionConfig(kind: .postgres, port: 5432, user: "u")
        tunnel.ssh = SSHConfig(host: "", user: "me")
        XCTAssertFalse(ConnectionFormRules.isValid(tunnel), "an SSH server without a host")
        XCTAssertTrue(ConnectionFormRules.isValid(ConnectionConfig(kind: .redis, port: 6379, database: "3")))
        XCTAssertFalse(ConnectionFormRules.isValid(ConnectionConfig(kind: .redis, port: 6379, database: "x")))
        var atlas = ConnectionConfig(kind: .mongodb, host: "cluster0.example.mongodb.net", port: 0)
        atlas.srv = true
        XCTAssertTrue(ConnectionFormRules.isValid(atlas), "a seed list takes its port from DNS")
        XCTAssertFalse(
            ConnectionFormRules.isValid(ConnectionConfig(kind: .mongodb, host: "", port: 27017)),
            "needs a host"
        )
    }
}
