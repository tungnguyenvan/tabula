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

    func testSchemaDescribesQualifiedNamesTypesAndKeys() {
        let schema = SQLPrompts.Schema(tables: [
            .init(name: "dev.transactions", columns: [.init(name: "id", type: "uuid", isPrimaryKey: true), .init(name: "amount", type: "numeric")]),
            .init(name: "dev.merchants", columns: []),
        ], foreignKeys: ["dev.transactions.merchant_id -> dev.merchants.id"], defaultSchema: "dev")
        XCTAssertEqual(schema.text, """
            Default schema: dev
            dev.transactions(id uuid PK, amount numeric)
            dev.merchants
            Foreign keys:
            dev.transactions.merchant_id -> dev.merchants.id
            """)
        let request = SQLPrompts.generate(description: "today's total", current: nil, schema: schema, kind: .postgres)
        XCTAssertTrue(request.instructions.contains("keeping any schema prefix"))
    }

    func testCustomInstructions() {
        let schema = SQLPrompts.Schema(tables: [])
        let custom = SQLPrompts.chat(question: "hi", history: [], editorSQL: nil, schema: schema, kind: .mysql,
                                     instructions: "Answer in Vietnamese. You help with {database}.")
        XCTAssertEqual(custom.instructions, "Answer in Vietnamese. You help with MySQL / MariaDB.")
        // Empty means the default.
        let fallback = SQLPrompts.generate(description: "x", current: nil, schema: schema, kind: .postgres, instructions: "  ")
        XCTAssertTrue(fallback.instructions.hasPrefix("You write PostgreSQL SQL"))
        var settings = AISettings()
        settings.prompts["fix"] = "Be terse."
        XCTAssertEqual(settings.instructions(.fix), "Be terse.")
        XCTAssertNil(settings.instructions(.chat))
    }

    func testEffortGoesToAskAINotToTyping() {
        var settings = AISettings()
        settings.provider = .anthropic
        settings.efforts["anthropic"] = "xhigh"
        XCTAssertEqual(settings.endpoint(for: .generate, apiKey: "").effort, "xhigh")
        XCTAssertNil(settings.endpoint(for: .inline, apiKey: "").effort)
        settings.efforts["anthropic"] = "bogus"
        XCTAssertNil(settings.endpoint(for: .generate, apiKey: "").effort)
        XCTAssertTrue(AIProviderKind.builtIn.effortLevels.isEmpty)
    }

    func testErrorsAreRedactedBeforeTheyGoToAModel() {
        XCTAssertEqual(SQLPrompts.redacted(#"duplicate key value violates unique constraint "users_email_key" DETAIL: Key (email)=(an@example.com) already exists."#),
                       #"duplicate key value violates unique constraint "users_email_key" DETAIL: Key (email)=(…) already exists."#)
        XCTAssertEqual(SQLPrompts.redacted("invalid input syntax for type integer: 'abc'"), "invalid input syntax for type integer: '…'")
        XCTAssertEqual(SQLPrompts.redacted("Incorrect integer value: 'x1' for column 'age'"), "Incorrect integer value: '…' for column '…'")
        // MongoDB reports the existing document's values in the duplicate key, in double quotes.
        let duplicate = #"E11000 duplicate key error collection: shop.users index: email_1 dup key: { email: "ann@example.com", n: { a: 5 } }"#
        XCTAssertEqual(SQLPrompts.redacted(duplicate, kind: .mongodb),
                       "E11000 duplicate key error collection: shop.users index: email_1 dup key: { … }")
        XCTAssertEqual(SQLPrompts.redacted(#"Document failed validation: ssn "123-45-6789""#, kind: .mongodb),
                       #"Document failed validation: ssn "…""#)
        XCTAssertEqual(SQLPrompts.redacted(#"relation "orders" does not exist"#), #"relation "orders" does not exist"#)
        let fix = SQLPrompts.fix(sql: "INSERT INTO users VALUES (1, 'an@example.com')", error: "Key (id)=(1) already exists.",
                                 schema: SQLPrompts.Schema(tables: []), kind: .postgres)
        XCTAssertFalse(fix.prompt.contains("Key (id)=(1)"))
    }

    func testSettingsPerProviderAndPurpose() throws {
        var settings = AISettings()
        XCTAssertFalse(settings.enabled)
        settings.provider = .anthropic
        XCTAssertEqual(settings.model(.anthropic, for: .generate), "claude-opus-5-5")
        XCTAssertEqual(settings.model(.anthropic, for: .inline), "claude-opus-5-5")
        settings.inlineModels["anthropic"] = "claude-haiku-5-5"
        XCTAssertEqual(settings.endpoint(for: .inline, apiKey: "k").model, "claude-haiku-5-5")

        // Ask AI through Claude Code, suggestions from a small local model.
        settings.provider = .claudeCode
        settings.inlineProvider = .ollama
        XCTAssertEqual(settings.provider(for: .generate), .claudeCode)
        XCTAssertEqual(settings.endpoint(for: .inline, apiKey: "").kind, .ollama)
        XCTAssertEqual(settings.endpoint(for: .inline, apiKey: "").model, "qwen2.5-coder:0.5b")
        XCTAssertEqual(settings.endpoint(for: .inline, apiKey: "").baseURL, "http://localhost:11434")
        // Switching providers keeps each one's settings.
        settings.provider = .anthropic
        XCTAssertEqual(settings.model(.anthropic, for: .inline), "claude-haiku-5-5")

        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        // Settings saved before these fields existed still load.
        let old = try JSONDecoder().decode(AISettings.self, from: Data(#"{"enabled":true,"provider":"ollama"}"#.utf8))
        XCTAssertTrue(old.enabled)
        XCTAssertEqual(old.provider, .ollama)
        XCTAssertNil(old.inlineProvider)
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
        let endpoint = AISettings().endpoint(for: .generate, apiKey: "sk-test")
        StubProtocol.response = (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"SELECT 1"}]}"#)
        let reply = try await AnthropicProvider(AIEndpoint(kind: .anthropic, model: "claude-opus-5-5", apiKey: endpoint.apiKey)).complete(request)
        XCTAssertEqual(reply, "SELECT 1")
        let sent = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), Defaults.AI.anthropicVersion)
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["output_config"])

        _ = try await AnthropicProvider(AIEndpoint(kind: .anthropic, model: "claude-opus-5-5", apiKey: "k", effort: "high")).complete(request)
        XCTAssertEqual((StubProtocol.lastBody?["output_config"] as? [String: String])?["effort"], "high")
    }

    func testAnthropicRefusalAndErrors() async {
        let anthropic = AIEndpoint(kind: .anthropic, model: "claude-opus-5-5", apiKey: "k")
        StubProtocol.response = (200, #"{"stop_reason":"refusal","content":[]}"#)
        await assertThrows(AIError.refused) { try await AnthropicProvider(anthropic).complete(self.request) }
        StubProtocol.response = (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        await assertThrows(AIError.server("Claude API: invalid x-api-key")) {
            try await AnthropicProvider(anthropic).complete(self.request)
        }
        await assertThrows(AIError.notConfigured("Add a Claude API key in Settings → AI.")) {
            try await AnthropicProvider(AIEndpoint(kind: .anthropic, model: "claude-opus-5-5")).complete(self.request)
        }
    }

    func testOpenAICompatibleAndOllama() async throws {
        StubProtocol.response = (200, #"{"choices":[{"message":{"role":"assistant","content":"SELECT 2"}}]}"#)
        let reply = try await OpenAICompatibleProvider(AIEndpoint(kind: .openAICompatible, baseURL: "http://litellm.local:4000/v1",
                                                                  model: "gpt-test", apiKey: "key")).complete(request)
        XCTAssertEqual(reply, "SELECT 2")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "http://litellm.local:4000/v1/chat/completions")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let messages = try XCTUnwrap(StubProtocol.lastBody?["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertNil(StubProtocol.lastBody?["reasoning_effort"])
        _ = try await OpenAICompatibleProvider(AIEndpoint(kind: .openAICompatible, baseURL: "http://litellm.local:4000/v1",
                                                          model: "o-test", effort: "medium")).complete(request)
        XCTAssertEqual(StubProtocol.lastBody?["reasoning_effort"] as? String, "medium")

        _ = try await OllamaProvider(AIEndpoint(kind: .ollama, baseURL: "http://localhost:11434/", model: "qwen2.5-coder:1.5b")).complete(request)
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
    func testInputGoesThroughStdin() async throws {
        let output = try await ShellCommand.run(script: "cat", arguments: [], input: "SELECT 'secret'", timeout: 30)
        XCTAssertTrue(output.stdout.hasSuffix("SELECT 'secret'"), output.stdout)
    }

    func testRunsWithArgumentsKeptSeparate() async throws {
        let output = try await ShellCommand.run(script: #"printf '%s|' "$0" "$@""#, arguments: ["a b", "$HOME", "; rm"], timeout: 30)
        XCTAssertTrue(output.stdout.hasSuffix("a b|$HOME|; rm|"), output.stdout)
        XCTAssertEqual(output.status, 0)
    }

    func testExitedCommandDoesNotWaitForBackgroundChildsPipes() async throws {
        let start = Date()
        // The shell exits, but the disowned child inherits both pipes and keeps them open.
        let output = try await ShellCommand.run(script: "sleep 8 & disown; printf done; printf error >&2", arguments: [], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "waited for the background child's EOF after the shell exited")
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.hasSuffix("done"), output.stdout)
        XCTAssertTrue(output.stderr.contains("error"), output.stderr)
    }

    func testDrainsOutputBeforeReturning() async throws {
        let output = try await ShellCommand.run(script: "awk 'BEGIN { for (i = 0; i < 20000; i++) print \"line\"; printf \"tail\" }'", arguments: [], timeout: 30)
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.hasSuffix(String(repeating: "line\n", count: 20000) + "tail"))
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
        let reply = try await CLIProvider(tool: tool, effort: "low")
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

final class LocalModelTests: XCTestCase {
    func testStoreRefusesFilesThatAreNotGGUF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-models-\(UUID())")
        let store = LocalModelStore(directory: directory)
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID()).gguf")
        try Data("<html>not found</html>".utf8).write(to: bogus)
        XCTAssertThrowsError(try store.add(bogus))
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertThrowsError(try store.model(from: URL(string: "https://example.com/model.bin")!))
        XCTAssertEqual(try store.model(from: URL(string: "https://huggingface.co/a/b/resolve/main/m.gguf")!).id, "m.gguf")
        XCTAssertTrue(LocalModel.catalog.allSatisfy { $0.sha256?.count == 64 && $0.size > 0 })
    }

    /// Downloads the smallest catalog model (about 490 MB) and runs it in-process.
    /// Set TABULA_TEST_LOCAL_MODEL=1 (and optionally TABULA_TEST_MODELS_DIR to reuse a download).
    func testDownloadAndRunLive() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_LOCAL_MODEL"] != nil else { throw XCTSkip("TABULA_TEST_LOCAL_MODEL not set") }
        let directory = ProcessInfo.processInfo.environment["TABULA_TEST_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tabula-models")
        let store = LocalModelStore(directory: directory)
        let model = try XCTUnwrap(LocalModel.catalog.first)
        if !store.isInstalled(model.id) { try await store.download(model) { _ in } }
        XCTAssertTrue(store.isInstalled(model.id))

        let schema = SQLPrompts.Schema(tables: [.init(name: "dev.transactions", columns: [
            .init(name: "id", type: "uuid", isPrimaryKey: true), .init(name: "amount", type: "numeric"), .init(name: "created_at", type: "timestamptz"),
        ])], defaultSchema: "dev")
        let provider = BuiltInProvider(AIEndpoint(kind: .builtIn, model: model.id), store: store)
        let start = Date()
        let reply = try await provider.complete(SQLPrompts.generate(description: "total amount of all transactions", current: nil, schema: schema, kind: .postgres))
        let sql = SQLPrompts.cleanSQL(reply)
        print("LOCAL MODEL (\(Int(Date().timeIntervalSince(start) * 1000)) ms): \(sql)")
        XCTAssertTrue(sql.uppercased().contains("SUM"), sql)
        XCTAssertTrue(sql.contains("dev.transactions"), sql)

        // Suggestions while typing: fill in the middle, one short line, quickly (the model is loaded).
        for before in ["SELECT * FROM dev.transactions WHERE ", "SELECT SUM(amount) FROM dev.transactions WHERE created_at >= ", "SELECT id, amo"] {
            let typingStart = Date()
            let raw = try await provider.complete(SQLPrompts.inline(before: before, after: "", schema: schema, kind: .postgres))
            let inline = SQLPrompts.cleanContinuation(raw, before: before)
            print("LOCAL INLINE (\(Int(Date().timeIntervalSince(typingStart) * 1000)) ms): \(before)⟨\(inline)⟩")
            XCTAssertFalse(inline.contains("\n"))
        }
        // Streaming: the answer arrives token by token.
        var pieces: [String] = []
        for try await event in provider.stream(SQLPrompts.generate(description: "count the transactions", current: nil, schema: schema, kind: .postgres)) {
            if case .text(let piece) = event { pieces.append(piece) }
        }
        XCTAssertGreaterThan(pieces.count, 3, "expected the answer in several pieces")
        XCTAssertTrue(pieces.joined().uppercased().contains("COUNT"), pieces.joined())

        // The app frees the model before quitting too; llama.cpp aborts if Metal resources outlive it.
        LocalModelRunner.shared.unload()
    }
}
