import XCTest

@testable import Tabula
@testable import TabulaAI
@testable import TabulaFoundation
@testable import TabulaSQLite

/// The AI chat end to end: a scripted model behind a local OpenAI-compatible server asks for a query, Tabula runs
/// it read-only on its own connection, and the model answers from the result. The provider is set for the test and
/// put back after; the key comes from TABULA_AI_KEY, so the Keychain isn't touched.
@MainActor
final class AIChatSendTests: XCTestCase {

    private var server: FakeModelServer?
    private var port = 0
    private var folder: URL!
    private var savedSettings: AISettings?
    private var workspace: WorkspaceModel?

    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    override func setUp() async throws {
        try TestDataDirectory.check()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try await FakeModelServer.start(in: folder)
        self.server = server
        port = server.port

        savedSettings = AIService.shared.settings
        var settings = AIService.shared.settings
        settings.enabled = true
        settings.provider = .openAICompatible
        settings.baseURLs[AIProviderKind.openAICompatible.rawValue] = "http://127.0.0.1:\(port)/v1"
        settings.models[AIProviderKind.openAICompatible.rawValue] = "scripted"
        settings.assistantQueries = true
        AIService.shared.settings = settings
        setenv("TABULA_AI_KEY", "test-key", 1)

        let database = folder.appendingPathComponent("shop.sqlite").path
        let seed = try SQLiteDriver(path: database)
        _ = try await seed.executeScript(
            """
            CREATE TABLE orders (id INTEGER PRIMARY KEY);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 42) INSERT INTO orders SELECT x FROM c;
            """
        )
        await seed.close()
        self.database = database
    }

    private var database = ""

    override func tearDown() async throws {
        await workspace?.disconnect()
        workspace = nil
        if let savedSettings {
            AIService.shared.settings = savedSettings
        }
        unsetenv("TABULA_AI_KEY")
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func connect(tag: ConnectionTag) async throws -> WorkspaceModel {
        var config = ConnectionConfig(kind: .sqlite, filePath: database)
        config.tag = tag
        let workspace = WorkspaceModel(config: config, password: nil)
        self.workspace = workspace
        await workspace.connect()
        XCTAssertEqual(workspace.status, .connected)
        return workspace
    }

    private func waitUntilIdle(_ chat: AIChatModel) async throws {
        for _ in 0..<500 where chat.busy {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(chat.busy)
    }

    func testTheModelQueriesAndAnswersFromTheResult() async throws {
        let workspace = try await connect(tag: .local)
        let chat = workspace.chat
        chat.input = "How many orders are there?"
        chat.send(workspace: workspace, editorSQL: nil)
        try await waitUntilIdle(chat)
        XCTAssertNil(chat.error)
        let step = try XCTUnwrap(chat.messages.first { $0.role == .tool }?.tool)
        XCTAssertEqual(step.call.query, "SELECT count(*) AS n FROM orders")
        XCTAssertEqual(step.status, .done)
        XCTAssertTrue(step.result.contains("42"), step.result)
        XCTAssertEqual(chat.messages.last?.text, "There are 42 orders.")
        XCTAssertEqual(
            chat.messages.first { $0.role == .assistant }?.text,
            "Let me count.",
            "the tool request itself isn't shown as text"
        )
        // Saved for the next time the connection opens.
        XCTAssertEqual(AppState.chatStore.load(workspace.connectionID).conversations.first?.title, chat.title)
    }

    /// On Production each query waits for the user; refusing it lets the model answer without it.
    func testProductionQueriesWaitForApproval() async throws {
        var settings = AIService.shared.settings
        settings.allowProduction = true
        AIService.shared.settings = settings
        let workspace = try await connect(tag: .production)
        let chat = workspace.chat
        chat.input = "How many orders are there?"
        chat.send(workspace: workspace, editorSQL: nil)
        var waiting: ChatMessage?
        for _ in 0..<500 {
            waiting = chat.messages.first { $0.tool?.status == .awaitingApproval }
            if waiting != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let step = try XCTUnwrap(waiting)
        chat.answer(step.id, allow: false)
        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.messages.first { $0.id == step.id }?.tool?.status, .denied)
        XCTAssertEqual(chat.messages.last?.text, "I couldn't see the count.")
    }

    func testAIOffForProductionByDefault() async throws {
        var settings = AIService.shared.settings
        settings.allowProduction = false
        AIService.shared.settings = settings
        let workspace = try await connect(tag: .production)
        let chat = workspace.chat
        chat.input = "How many orders are there?"
        chat.send(workspace: workspace, editorSQL: nil)
        XCTAssertEqual(chat.error, "AI is off for Production connections. You can allow it in Settings › AI.")
        XCTAssertTrue(chat.messages.isEmpty)
    }
}
