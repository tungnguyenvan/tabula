import Foundation
import XCTest

/// A scripted OpenAI-compatible chat server on 127.0.0.1, for the AI chat and Ask AI tests. It streams
/// server-sent events like the real API; what it answers depends on the prompt (see the script).
final class FakeModelServer {
    private static let script = #"""

        # A scripted OpenAI-compatible chat server for Tabula's tests: the first answer asks for a query, the next one
        # says what the query returned. Streams server-sent events like the real API.
        import json, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                prompt = body["messages"][-1]["content"]
                if "Write SQL for the test" in prompt:
                    text = "Here it is:\n```sql\nSELECT count(*) FROM orders\n```"
                elif "Write nothing for the test" in prompt:
                    text = "```sql\n```"
                elif "Result:" not in prompt:
                    text = "Let me count.\n```tool\n{\"tool\": \"run_query\", \"query\": \"SELECT count(*) AS n FROM orders\"}\n```"
                else:
                    result = prompt.split("Result:", 1)[1]
                    text = "There are 42 orders." if "42" in result else "I couldn't see the count."
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for piece in [text[i:i + 12] for i in range(0, len(text), 12)]:
                    chunk = {"choices": [{"delta": {"content": piece}}]}
                    self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")

        HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
        """#

    let port: Int
    private let process: Process

    private init(port: Int, process: Process) {
        self.port = port
        self.process = process
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// Writes the script to `folder` and starts it, waiting until it listens.
    static func start(in folder: URL) async throws -> FakeModelServer {
        let file = folder.appendingPathComponent("server.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let port = Int.random(in: 40_000..<60_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", file.path, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let server = FakeModelServer(port: port, process: process)
        // Listening once a connection is accepted (a GET is refused with 501, which still means it is up).
        for _ in 0..<100 {
            if let (_, response) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!),
                response is HTTPURLResponse
            {
                return server
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        server.stop()
        throw XCTSkip("The fake model server didn't start.")
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}
