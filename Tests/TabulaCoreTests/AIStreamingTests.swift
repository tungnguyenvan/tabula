import XCTest
@testable import TabulaCore

final class ThinkTagSplitterTests: XCTestCase {
    /// Feeds `chunks` one by one and joins the events of each kind.
    private func split(_ chunks: [String]) -> (thinking: String, text: String) {
        var splitter = ThinkTagSplitter()
        var events = chunks.flatMap { splitter.feed($0) }
        events += splitter.finish()
        var thinking = "", text = ""
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
        var thinking = "", text = ""
        for try await event in stream {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece): text += piece
            }
        }
        return (thinking, text)
    }

    func testAnthropicStreamsThinkingAndText() async throws {
        StubProtocol.response = (200, """
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

            """)
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
        do { _ = try await collect(AnthropicProvider(endpoint).stream(request)); XCTFail("expected a refusal") } catch {
            XCTAssertEqual(error as? AIError, .refused)
        }
        StubProtocol.response = (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        do { _ = try await collect(AnthropicProvider(endpoint).stream(request)); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? AIError, .server("Claude API: Overloaded"))
        }
    }

    func testInlineRequestsDoNotAskForThinking() async throws {
        StubProtocol.response = (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"1"}]}"#)
        let inline = AIRequest(purpose: .inline, instructions: "x", prompt: "y")
        _ = try await AnthropicProvider(AIEndpoint(kind: .anthropic, model: "claude-haiku-5-5", apiKey: "k")).complete(inline)
        XCTAssertNil(StubProtocol.lastBody?["thinking"])
    }

    func testOpenAICompatibleStreamsReasoningFields() async throws {
        StubProtocol.response = (200, """
            data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

            data: {"choices":[{"delta":{"reasoning_content":"Think "}}]}

            data: {"choices":[{"delta":{"reasoning":"more."}}]}

            data: {"choices":[{"delta":{"content":"SELECT 2"}}]}

            data: [DONE]

            """)
        let endpoint = AIEndpoint(kind: .openAICompatible, baseURL: "http://localhost:4000/v1", model: "m")
        let result = try await collect(OpenAICompatibleProvider(endpoint).stream(request))
        XCTAssertEqual(result.thinking, "Think more.")
        XCTAssertEqual(result.text, "SELECT 2")
        XCTAssertEqual(StubProtocol.lastBody?["stream"] as? Bool, true)
    }

    func testOpenAICompatibleSplitsThinkTags() async throws {
        StubProtocol.response = (200, """
            data: {"choices":[{"delta":{"content":"<think>Which"}}]}

            data: {"choices":[{"delta":{"content":" table?</think>\\n\\nSELECT 3"}}]}

            data: [DONE]

            """)
        let endpoint = AIEndpoint(kind: .openAICompatible, baseURL: "http://localhost:4000/v1", model: "m")
        let result = try await collect(OpenAICompatibleProvider(endpoint).stream(request))
        XCTAssertEqual(result.thinking, "Which table?")
        XCTAssertEqual(result.text, "SELECT 3")
        // Without streaming the reasoning is left out of the answer too.
        StubProtocol.response = (200, #"{"choices":[{"message":{"content":"<think>hmm</think>SELECT 4"}}]}"#)
        let reply = try await OpenAICompatibleProvider(endpoint).complete(request)
        XCTAssertEqual(reply, "SELECT 4")
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
    private func run(_ lines: [String], _ feed: (CLIEvents, String) -> Void) async throws -> (thinking: String, text: String, events: CLIEvents) {
        var captured: CLIEvents!
        let stream = AIStream { continuation in
            let events = CLIEvents(continuation)
            captured = events
            lines.forEach { feed(events, $0) }
            continuation.finish()
        }
        var thinking = "", text = ""
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
            #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"SELECT 1"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ]) { $0.codex($1) }
        XCTAssertEqual(current.thinking, "Look at the schema\n\n")
        XCTAssertEqual(current.text, "SELECT 1")
        let older = try await run([
            #"{"id":"0","msg":{"type":"agent_reasoning_delta","delta":"Hm"}}"#,
            #"{"id":"0","msg":{"type":"agent_message_delta","delta":"SELECT "}}"#,
            #"{"id":"0","msg":{"type":"agent_message_delta","delta":"2"}}"#,
            #"{"id":"0","msg":{"type":"agent_message","message":"SELECT 2"}}"#,
        ]) { $0.codex($1) }
        XCTAssertEqual(older.thinking, "Hm")
        XCTAssertEqual(older.text, "SELECT 2")
        let failed = try await run([#"{"type":"turn.failed","error":{"message":"quota"}}"#]) { $0.codex($1) }
        XCTAssertEqual(failed.events.failure, "quota")
    }

    /// Runs the installed Claude Code (TABULA_TEST_CLAUDE_CODE=1), which costs a small request.
    func testClaudeCodeStreamsLive() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_CLAUDE_CODE"] != nil else { throw XCTSkip("TABULA_TEST_CLAUDE_CODE not set") }
        let provider = CLIProvider(tool: .claude, model: "claude-haiku-5-5")
        var thinking = "", text = "", pieces = 0
        for try await event in provider.stream(AIRequest(purpose: .generate, instructions: "Answer in one short sentence.",
                                                        prompt: "Think it through, then say what SQL's COUNT(*) does.")) {
            switch event {
            case .thinking(let piece): thinking += piece
            case .text(let piece): text += piece; pieces += 1
            }
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertGreaterThan(pieces + (thinking.isEmpty ? 0 : 1), 1, "expected the answer in more than one piece")
    }
}
