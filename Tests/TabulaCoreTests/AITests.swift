import XCTest
@testable import TabulaCore

final class SQLPromptsTests: XCTestCase {
    func testCleanSQLRemovesFences() {
        XCTAssertEqual(SQLPrompts.cleanSQL("```sql\nSELECT 1;\n```"), "SELECT 1;")
        XCTAssertEqual(SQLPrompts.cleanSQL("Here you go:\n```\nSELECT 2\n```\nEnjoy"), "SELECT 2")
        XCTAssertEqual(SQLPrompts.cleanSQL("  SELECT 3  "), "SELECT 3")
    }

    func testContinuation() {
        // The word being completed isn't repeated, and only one line is kept.
        XCTAssertEqual(SQLPrompts.cleanContinuation("customers WHERE id = 1\nLIMIT 5", before: "SELECT * FROM cust"), "omers WHERE id = 1")
        XCTAssertEqual(SQLPrompts.cleanContinuation(" WHERE active", before: "SELECT * FROM users "), "WHERE active")
        XCTAssertEqual(SQLPrompts.cleanContinuation("```\nORDER BY id\n```", before: "SELECT * FROM t "), "ORDER BY id")
    }

    func testPromptsCarrySchemaButNoRows() {
        let schema = SQLPrompts.Schema(tables: [("orders", ["id", "total"]), ("users", ["id", "email"])])
        let request = SQLPrompts.generate(description: "biggest orders", current: nil, schema: schema, kind: .postgres)
        XCTAssertTrue(request.prompt.contains("orders(id, total)"))
        XCTAssertTrue(request.instructions.contains("PostgreSQL"))
        XCTAssertEqual(request.purpose, .generate)
        let edit = SQLPrompts.generate(description: "add a limit", current: "SELECT * FROM orders", schema: schema, kind: .mysql)
        XCTAssertTrue(edit.prompt.contains("Current SQL:\nSELECT * FROM orders"))
        let inline = SQLPrompts.inline(before: String(repeating: "x", count: 5000) + "SELECT ", after: "", schema: schema, kind: .sqlite)
        XCTAssertLessThanOrEqual(inline.prompt.count, schema.text.count + Defaults.AI.inlineContextLength + 40)
    }

    func testSettingsDefaults() throws {
        var settings = AISettings()
        XCTAssertFalse(settings.enabled)
        settings.provider = .anthropic
        XCTAssertEqual(settings.resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(settings.modelName(for: .inline), "claude-opus-5-5")
        settings.inlineModel = "claude-haiku-5-5"
        XCTAssertEqual(settings.modelName(for: .inline), "claude-haiku-5-5")
        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(AIProviderKind.codex.supportsInline)
    }
}

/// Answers HTTP requests from the providers without touching the network, and records them.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: String) = (200, "{}")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else if let body = request.httpBody {
            Self.lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AIProviderTests: XCTestCase {
    override func setUp() { URLProtocol.registerClass(StubProtocol.self) }
    override func tearDown() { URLProtocol.unregisterClass(StubProtocol.self) }

    private let request = AIRequest(purpose: .generate, instructions: "Be brief.", prompt: "SELECT?")

    func testAnthropicRequestAndReply() async throws {
        var settings = AISettings()
        settings.provider = .anthropic
        StubProtocol.response = (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"SELECT 1"}]}"#)
        let reply = try await AnthropicProvider(settings: settings, apiKey: "sk-test").complete(request)
        XCTAssertEqual(reply, "SELECT 1")
        let sent = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), Defaults.AI.anthropicVersion)
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        XCTAssertNil(body["temperature"])
    }

    func testAnthropicRefusalAndErrors() async {
        var settings = AISettings()
        settings.provider = .anthropic
        StubProtocol.response = (200, #"{"stop_reason":"refusal","content":[]}"#)
        await assertThrows(AIError.refused) { try await AnthropicProvider(settings: settings, apiKey: "k").complete(self.request) }
        StubProtocol.response = (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        await assertThrows(AIError.server("Claude API: invalid x-api-key")) {
            try await AnthropicProvider(settings: settings, apiKey: "k").complete(self.request)
        }
        await assertThrows(AIError.notConfigured("Add a Claude API key in Settings → AI.")) {
            try await AnthropicProvider(settings: settings, apiKey: "").complete(self.request)
        }
    }

    func testOpenAICompatibleAndOllama() async throws {
        var settings = AISettings()
        settings.provider = .openAICompatible
        settings.baseURL = "http://litellm.local:4000/v1"
        settings.model = "gpt-test"
        StubProtocol.response = (200, #"{"choices":[{"message":{"role":"assistant","content":"SELECT 2"}}]}"#)
        let reply = try await OpenAICompatibleProvider(settings: settings, apiKey: "key").complete(request)
        XCTAssertEqual(reply, "SELECT 2")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "http://litellm.local:4000/v1/chat/completions")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let messages = try XCTUnwrap(StubProtocol.lastBody?["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])

        settings.provider = .ollama
        settings.baseURL = ""
        settings.model = "qwen2.5-coder:1.5b"
        _ = try await OllamaProvider(settings: settings).complete(request)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    private func assertThrows(_ expected: AIError, _ body: @escaping () async throws -> String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIError, expected, file: file, line: line)
        }
    }
}

final class ShellCommandTests: XCTestCase {
    func testRunsWithArgumentsKeptSeparate() async throws {
        let output = try await ShellCommand.run(script: #"printf '%s|' "$0" "$@""#, arguments: ["a b", "$HOME", "; rm"], timeout: 30)
        XCTAssertTrue(output.stdout.hasSuffix("a b|$HOME|; rm|"), output.stdout)
        XCTAssertEqual(output.status, 0)
    }

    func testTimeoutStopsTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-timeout-\(UUID()).txt")
        let start = Date()
        do {
            _ = try await ShellCommand.run(script: #"sleep 5; touch "$0""#, arguments: [marker.path], timeout: 2)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }
        try await Task.sleep(for: .seconds(4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the command kept running after the timeout")
    }

    /// Runs the installed Claude Code / Codex CLI; set TABULA_TEST_AI_CLI=claude or codex. Uses the account's quota.
    func testCommandLineAgentLive() async throws {
        guard let name = ProcessInfo.processInfo.environment["TABULA_TEST_AI_CLI"], let tool = CLIProvider.Tool(rawValue: name) else {
            throw XCTSkip("TABULA_TEST_AI_CLI not set")
        }
        guard await CLIProvider.locate(tool) != nil else { throw XCTSkip("\(name) is not installed") }
        let schema = SQLPrompts.Schema(tables: [("orders", ["id", "customer_id", "total"])])
        let reply = try await CLIProvider(tool: tool, settings: AISettings())
            .complete(SQLPrompts.generate(description: "count the orders", current: nil, schema: schema, kind: .postgres))
        let sql = SQLPrompts.cleanSQL(reply)
        XCTAssertTrue(sql.uppercased().contains("COUNT"), sql)
        XCTAssertFalse(sql.contains("```"), sql)
    }

    /// Talks to Apple's on-device model; set TABULA_TEST_APPLE_AI=1 on a Mac with Apple Intelligence.
    func testAppleIntelligenceLive() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_APPLE_AI"] != nil else { throw XCTSkip("TABULA_TEST_APPLE_AI not set") }
        if let reason = AppleIntelligenceProvider.unavailableReason { throw XCTSkip(reason) }
        let schema = SQLPrompts.Schema(tables: [("orders", ["id", "customer_id", "total", "created_at"])])
        let reply = try await AppleIntelligenceProvider().complete(SQLPrompts.generate(description: "the 5 biggest orders", current: nil, schema: schema, kind: .postgres))
        let sql = SQLPrompts.cleanSQL(reply)
        XCTAssertTrue(sql.uppercased().contains("SELECT"), sql)
        XCTAssertTrue(sql.lowercased().contains("orders"), sql)
    }
}
