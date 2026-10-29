import XCTest

@testable import TabulaAI

final class ThinkTagSplitterTests: XCTestCase {
    /// Feeds `chunks` one by one and joins the events of each kind.
    private func split(_ chunks: [String]) -> (thinking: String, text: String) {
        var splitter = ThinkTagSplitter()
        var events = chunks.flatMap { splitter.feed($0) }
        events += splitter.finish()
        var thinking = ""
        var text = ""
        for event in events {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece): text += piece
            }
        }
        return (thinking, text)
    }

    func testTagsSplitAcrossChunks() {
        let result = split(["  <thi", "nk>Check the", " schema.</th", "ink>\n\nSELECT", " 1;"])
        XCTAssertEqual(result.thinking, "Check the schema.")
        XCTAssertEqual(result.text, "SELECT 1;")
    }

    func testPlainAnswersAndLateTags() {
        XCTAssertEqual(split(["SELECT ", "1"]).text, "SELECT 1")
        XCTAssertEqual(split(["SELECT ", "1"]).thinking, "")
        // A tag after the answer began is part of the answer.
        XCTAssertEqual(split(["Use ", "<think> tags"]).text, "Use <think> tags")
        // An unfinished reasoning block is still reasoning.
        XCTAssertEqual(split(["<think>half a thought"]).thinking, "half a thought")
        XCTAssertEqual(split(["<", "b>bold</b>"]).text, "<b>bold</b>")
    }
}

final class AIStreamingTests: XCTestCase {
    override func setUp() { URLProtocol.registerClass(StubProtocol.self) }
    override func tearDown() { URLProtocol.unregisterClass(StubProtocol.self) }

    private let request = AIRequest(purpose: .generate, instructions: "Be brief.", prompt: "SELECT?")

    private func collect(_ stream: AIStream) async throws -> (thinking: String, text: String) {
        var thinking = ""
        var text = ""
        for try await event in stream {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece): text += piece
            }
        }
        return (thinking, text)
    }

    func testAnthropicStreamsThinkingAndText() async throws {
        StubProtocol.response = (
            200,
            """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1"}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants "}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a count."}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"SELECT "}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"count(*) FROM t"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        )
        let endpoint = AIEndpoint(kind: .anthropic, model: "claude-opus-5-5", apiKey: "k", effort: "high")
        let result = try await collect(AnthropicProvider(endpoint).stream(request))
        XCTAssertEqual(result.thinking, "The user wants a count.")
        XCTAssertEqual(result.text, "SELECT count(*) FROM t")
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["thinking"] as? [String: String])?["display"], "summarized")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "high")
    }

    func testAnthropicStreamErrors() async {
        let endpoint = AIEndpoint(kind: .anthropic, model: "claude-opus-5-5", apiKey: "k")
        StubProtocol.response = (200, "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n\n")
        do {
            _ = try await collect(AnthropicProvider(endpoint).stream(request))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AIError, .refused)
        }
        StubProtocol.response = (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        do {
            _ = try await collect(AnthropicProvider(endpoint).stream(request))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AIError, .server("Claude API: Overloaded"))
        }
    }

    func testInlineRequestsDoNotAskForThinking() async throws {
        StubProtocol.response = (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"1"}]}"#)
        let inline = AIRequest(purpose: .inline, instructions: "x", prompt: "y")
        _ = try await AnthropicProvider(AIEndpoint(kind: .anthropic, model: "claude-haiku-5-5", apiKey: "k"))
            .complete(inline)
        XCTAssertNil(StubProtocol.lastBody?["thinking"])
    }

    func testOpenAICompatibleStreamsReasoningFields() async throws {
        StubProtocol.response = (
            200,
            """
            data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

            data: {"choices":[{"delta":{"reasoning_content":"Think "}}]}

            data: {"choices":[{"delta":{"reasoning":"more."}}]}

            data: {"choices":[{"delta":{"content":"SELECT 2"}}]}

            data: [DONE]

            """
        )
        let endpoint = AIEndpoint(kind: .openAICompatible, baseURL: "http://localhost:4000/v1", model: "m")
        let result = try await collect(OpenAICompatibleProvider(endpoint).stream(request))
        XCTAssertEqual(result.thinking, "Think more.")
        XCTAssertEqual(result.text, "SELECT 2")
        XCTAssertEqual(StubProtocol.lastBody?["stream"] as? Bool, true)
    }

    func testOpenAICompatibleSplitsThinkTags() async throws {
        StubProtocol.response = (
            200,
            """
            data: {"choices":[{"delta":{"content":"<think>Which"}}]}

            data: {"choices":[{"delta":{"content":" table?</think>\\n\\nSELECT 3"}}]}

            data: [DONE]

            """
        )
        let endpoint = AIEndpoint(kind: .openAICompatible, baseURL: "http://localhost:4000/v1", model: "m")
        let result = try await collect(OpenAICompatibleProvider(endpoint).stream(request))
        XCTAssertEqual(result.thinking, "Which table?")
        XCTAssertEqual(result.text, "SELECT 3")
        // Without streaming the reasoning is left out of the answer too.
        StubProtocol.response = (200, #"{"choices":[{"message":{"content":"<think>hmm</think>SELECT 4"}}]}"#)
        let reply = try await OpenAICompatibleProvider(endpoint).complete(request)
        XCTAssertEqual(reply, "SELECT 4")
    }

    func testAdaptiveThinkingOnlyForModelsThatTakeIt() {
        for model in [
            "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-6",
            "claude-sonnet-4-6-20260115", "anthropic/claude-opus-5", "claude-opus-5-20260301",
        ] {
            XCTAssertTrue(AnthropicProvider.takesAdaptiveThinking(model), model)
        }
        for model in [
            "claude-haiku-4-5", "claude-sonnet-4-5-20250929", "claude-3-7-sonnet", "claude-opus-4-1", "gpt-5", "",
        ] {
            XCTAssertFalse(AnthropicProvider.takesAdaptiveThinking(model), model)
        }
    }

    func testCleanSQLDropsLeftoverReasoning() {
        XCTAssertEqual(
            SQLPrompts.cleanSQL("Okay, the user wants a count.</think>\n\nSELECT count(*) FROM t"),
            "SELECT count(*) FROM t"
        )
        XCTAssertEqual(SQLPrompts.cleanSQL("<think>hm</think>```sql\nSELECT 1\n```"), "SELECT 1")
    }

    func testCompleteUTF8Prefix() {
        let text = Data("Hà Nội".utf8)
        XCTAssertEqual(LocalModelRunner.completeUTF8Length(text), text.count)
        // "ộ" is three bytes; cutting it leaves the bytes before it.
        let cut = text.prefix(text.count - 2)
        XCTAssertEqual(LocalModelRunner.completeUTF8Length(Data(cut)), text.count - 4)
        XCTAssertEqual(LocalModelRunner.completeUTF8Length(Data()), 0)
    }
}

final class CLIEventsTests: XCTestCase {
    private func run(
        _ lines: [String],
        _ feed: (CLIEvents, String) -> Void
    ) async throws -> (thinking: String, text: String, events: CLIEvents) {
        var captured: CLIEvents!
        let stream = AIStream { continuation in
            let events = CLIEvents(continuation)
            captured = events
            lines.forEach { feed(events, $0) }
            continuation.finish()
        }
        var thinking = ""
        var text = ""
        for try await event in stream {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece): text += piece
            }
        }
        return (thinking, text, captured)
    }

    /// Lines as `claude -p --output-format stream-json --verbose --include-partial-messages` prints them (2.1.310).
    func testClaudeCodeStreamJSON() async throws {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Just as"}}}"#,
            #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":2}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ked."}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#,
            "not json",
        ]
        let result = try await run(lines) { $0.claude($1) }
        XCTAssertEqual(result.thinking, "Just asked.")
        XCTAssertEqual(result.text, "ok")
        XCTAssertTrue(result.events.sentText)
        XCTAssertEqual(result.events.result, "ok")
        let failed = try await run([#"{"type":"result","is_error":true,"result":"Not logged in"}"#]) { $0.claude($1) }
        XCTAssertEqual(failed.events.failure, "Not logged in")
    }

    func testCodexJSONL() async throws {
        let current = try await run([
            #"{"type":"thread.started","thread_id":"t"}"#,
            #"{"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"Look at the schema"}}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Let me check the tables."}}"#,
            #"{"type":"error","message":"Reconnecting... 1/5"}"#,
            #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"SELECT 1"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ]) { $0.codex($1) }
        // A progress note goes with the reasoning; the last message is the answer, sent when Codex finishes.
        XCTAssertEqual(current.thinking, "Look at the schema\n\nLet me check the tables.\n\n")
        XCTAssertEqual(current.text, "")
        XCTAssertEqual(current.events.lastMessage, "SELECT 1")
        let older = try await run([
            #"{"id":"0","msg":{"type":"agent_reasoning_delta","delta":"Hm"}}"#,
            #"{"id":"0","msg":{"type":"agent_message_delta","delta":"SELECT "}}"#,
            #"{"id":"0","msg":{"type":"agent_message_delta","delta":"2"}}"#,
            #"{"id":"0","msg":{"type":"agent_message","message":"SELECT 2"}}"#,
        ]) { $0.codex($1) }
        XCTAssertEqual(older.thinking, "Hm")
        XCTAssertEqual(older.text, "SELECT 2")
        XCTAssertTrue(older.events.sentText)
        let failed = try await run([#"{"type":"turn.failed","error":{"message":"quota"}}"#]) { $0.codex($1) }
        XCTAssertEqual(failed.events.failure, "quota")
    }

    /// The Claude Code command line, with a stand-in `claude` that records what it was given (#80): the user's
    /// hooks, MCP servers, slash commands and session saving are off, and the prompt arrives on standard input
    /// even when the shell's profile reads input of its own.
    func testClaudeCodeRunsWithoutTheUsersSetup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FakeClaude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = directory.appendingPathComponent("arguments.txt")
        let input = directory.appendingPathComponent("input.txt")
        let fake = directory.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(arguments.path)"
            cat > "\(input.path)"
            echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"SELECT 1"}}}'
            echo '{"type":"result","result":"SELECT 1"}'
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let provider = CLIProvider(tool: .claude, model: "", effort: nil, executable: fake.path)
        let reply = try await provider.complete(
            AIRequest(purpose: .generate, instructions: "Reply with SQL only.", prompt: "Count the rows of t.")
        )
        XCTAssertEqual(reply, "SELECT 1")
        let given = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        for flag in ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--tools"] {
            XCTAssertTrue(given.contains(flag), "missing \(flag) in \(given)")
        }
        let settings = given.firstIndex(of: "--settings").map { given[$0 + 1] }
        XCTAssertEqual(settings, #"{"disableAllHooks": true}"#)
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "Count the rows of t.")
    }

    /// Codex, with a stand-in `codex`: the user's MCP servers are turned off for the run, and the instructions and
    /// prompt arrive on standard input (`-`).
    func testCodexRunsWithoutTheUsersMCPServers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FakeCodex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = directory.appendingPathComponent("arguments.txt")
        let input = directory.appendingPathComponent("input.txt")
        let fake = directory.appendingPathComponent("codex")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(arguments.path)"
            cat > "\(input.path)"
            echo '{"type":"item.completed","item":{"type":"agent_message","text":"SELECT 2"}}'
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let provider = CLIProvider(tool: .codex, model: "", effort: nil, executable: fake.path)
        let reply = try await provider.complete(
            AIRequest(purpose: .generate, instructions: "Reply with SQL only.", prompt: "Count the rows of u.")
        )
        XCTAssertEqual(reply, "SELECT 2")
        let given = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        let override = given.firstIndex(of: "-c").map { given[$0 + 1] }
        XCTAssertEqual(override, "mcp_servers={}")
        XCTAssertEqual(given.last, "-", "the prompt comes on standard input")
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "Reply with SQL only.\n\nCount the rows of u.")
    }

    /// Runs the installed Codex (TABULA_TEST_CODEX=1), which costs a small request.
    func testCodexStreamsLive() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_CODEX"] != nil else {
            throw XCTSkip("TABULA_TEST_CODEX not set")
        }
        let provider = CLIProvider(tool: .codex, effort: "high")
        var thinking = ""
        var text = ""
        for try await event in provider.stream(
            AIRequest(
                purpose: .generate,
                instructions: "Reply with SQL only.",
                prompt:
                    "Tables: customers(id, name), orders(id, customer_id, total, status). Think it through, then write the top 5 customers by paid order value."
            )
        ) {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece): text += piece
            }
        }
        XCTAssertTrue(text.uppercased().contains("SELECT"), text)
        XCTAssertFalse(thinking.isEmpty, "expected Codex's reasoning summary")
        let reply = try await provider.complete(
            AIRequest(purpose: .generate, instructions: "Reply with SQL only.", prompt: "Count the rows of table t.")
        )
        XCTAssertTrue(reply.uppercased().contains("COUNT"), reply)
    }

    /// Runs the installed Claude Code (TABULA_TEST_CLAUDE_CODE=1), which costs a small request.
    func testClaudeCodeStreamsLive() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_CLAUDE_CODE"] != nil else {
            throw XCTSkip("TABULA_TEST_CLAUDE_CODE not set")
        }
        let provider = CLIProvider(tool: .claude, model: "claude-haiku-5-5")
        var thinking = ""
        var text = ""
        var pieces = 0
        for try await event in provider.stream(
            AIRequest(
                purpose: .generate,
                instructions: "Answer in one short sentence.",
                prompt: "Think it through, then say what SQL's COUNT(*) does."
            )
        ) {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece):
                text += piece
                pieces += 1
            }
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertGreaterThan(pieces + (thinking.isEmpty ? 0 : 1), 1, "expected the answer in more than one piece")
    }
}
