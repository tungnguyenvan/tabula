import XCTest

@testable import Tabula
@testable import TabulaAI
@testable import TabulaFoundation

/// Ask AI (⌘K) against the scripted model, and the command palette's matching.
@MainActor
final class QueryAssistantAndPaletteTests: XCTestCase {
    private var server: FakeModelServer?
    private var folder: URL!
    private var savedSettings: AISettings?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try await FakeModelServer.start(in: folder)
        self.server = server
        savedSettings = AIService.shared.settings
        var settings = AIService.shared.settings
        settings.enabled = true
        settings.provider = .openAICompatible
        settings.baseURLs[AIProviderKind.openAICompatible.rawValue] = server.baseURL
        settings.models[AIProviderKind.openAICompatible.rawValue] = "scripted"
        AIService.shared.settings = settings
        setenv("TABULA_AI_KEY", "test-key", 1)
    }

    override func tearDown() async throws {
        if let savedSettings {
            AIService.shared.settings = savedSettings
        }
        unsetenv("TABULA_AI_KEY")
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func ask(
        _ prompt: String,
        connection: ConnectionConfig = ConnectionConfig(kind: .sqlite, filePath: "/tmp/x")
    )
        async throws -> (QueryAssistant, String?)
    {
        let assistant = QueryAssistant()
        var applied: String?
        assistant.run(for: connection) {
            AIRequest(purpose: .generate, instructions: "Answer with SQL.", prompt: prompt)
        } apply: {
            applied = $0
        }
        for _ in 0..<500 where assistant.busy {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(assistant.busy)
        return (assistant, applied)
    }

    func testTheAnswersSQLIsInsertedWithoutItsFence() async throws {
        let (assistant, applied) = try await ask("Write SQL for the test")
        XCTAssertNil(assistant.error)
        XCTAssertEqual(applied, "SELECT count(*) FROM orders")
        XCTAssertFalse(assistant.showPrompt, "the prompt closes once the SQL is in")
    }

    func testAnEmptyAnswerIsReported() async throws {
        let (assistant, applied) = try await ask("Write nothing for the test")
        XCTAssertNil(applied)
        XCTAssertEqual(assistant.error, "The model returned nothing to insert.")
    }

    func testProductionIsRefusedUnlessAllowed() async throws {
        var settings = AIService.shared.settings
        settings.allowProduction = false
        AIService.shared.settings = settings
        var production = ConnectionConfig(kind: .sqlite, filePath: "/tmp/x")
        production.tag = .production
        let (assistant, applied) = try await ask("Write SQL for the test", connection: production)
        XCTAssertNil(applied)
        XCTAssertEqual(assistant.error, "AI is off for Production connections. You can allow it in Settings › AI.")
        XCTAssertTrue(assistant.showPrompt, "the prompt stays open to show why")
    }

    func testPaletteMatchesInOrderAndRanksWordStartsFirst() {
        XCTAssertNil(CommandPaletteView.score("orders", "sro"), "letters must come in order")
        XCTAssertNotNil(CommandPaletteView.score("Customer Orders", "co"))
        let titles = ["coordinates", "user_orders", "orders", "work_order_lines"]
        let ranked = titles.compactMap { title in CommandPaletteView.score(title, "ord").map { (title, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        XCTAssertEqual(ranked.first, "orders", "a match at the start, shortest name first")
        XCTAssertEqual(Array(ranked.prefix(3)).sorted(), ["orders", "user_orders", "work_order_lines"])
        XCTAssertEqual(ranked.last, "coordinates", "a match inside a word comes last")
        XCTAssertEqual(CommandPaletteView.score("ORDERS", "orders"), CommandPaletteView.score("orders", "ORDERS"))
    }
}
