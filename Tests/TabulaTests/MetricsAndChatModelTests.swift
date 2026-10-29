import XCTest

@testable import Tabula
@testable import TabulaAI
@testable import TabulaDrivers
@testable import TabulaFoundation

/// The metrics tab's rates, and the AI chat's saved conversations (in `TestDataDirectory`).
@MainActor
final class MetricsAndChatModelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    func testMetricsRatesFromCountersAndGauges() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = SampleQueue([
            MetricsSample(time: start, groups: [], counters: ["queries": 100], gauges: ["connections": 3]),
            MetricsSample(
                time: start.addingTimeInterval(2),
                groups: [],
                counters: ["queries": 160],
                gauges: ["connections": 5]
            ),
            // A server restart resets counters: no negative rate.
            MetricsSample(time: start.addingTimeInterval(4), groups: [], counters: ["queries": 10], gauges: [:]),
        ])
        let model = MetricsModel { try samples.next() }
        await model.refresh()
        XCTAssertEqual(model.rates, [:], "a rate needs two samples")
        await model.refresh()
        XCTAssertEqual(model.rates, ["queries": 30])
        XCTAssertEqual(model.seriesNames, ["queries", "connections"], "rates first, then gauges")
        XCTAssertEqual(model.points.filter { $0.series == "connections" }.map(\.value), [3, 5])
        await model.refresh()
        XCTAssertEqual(model.rates, [:])
        await model.refresh()
        XCTAssertEqual(model.error, "No more samples")
        XCTAssertNotNil(model.latest, "the last good sample stays")
    }

    func testChatOpensTheLatestConversationAndDeletes() throws {
        try TestDataDirectory.check()
        let connection = UUID()
        let older = ChatConversation(
            title: "Older",
            updated: Date(timeIntervalSince1970: 1),
            messages: [ChatMessage(role: .user, text: "first question")]
        )
        let newer = ChatConversation(
            title: "Newer",
            updated: Date(timeIntervalSince1970: 2),
            messages: [ChatMessage(role: .user, text: "second question")]
        )
        try AppState.chatStore.save([older, newer], for: connection)
        defer { try? AppState.chatStore.save([], for: connection) }

        let chat = AIChatModel(connectionID: connection)
        XCTAssertEqual(chat.title, "Newer")
        XCTAssertEqual(chat.messages.first?.text, "second question")
        chat.open(older.id)
        XCTAssertEqual(chat.title, "Older")

        chat.delete(older.id)
        XCTAssertEqual(chat.title, "New Chat", "deleting the open conversation starts a new one")
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(AppState.chatStore.load(connection).conversations.map(\.title), ["Newer"])

        // Another window's conversation, saved meanwhile, is kept when this one writes.
        let elsewhere = ChatConversation(
            title: "Elsewhere",
            updated: Date(timeIntervalSince1970: 3),
            messages: [ChatMessage(role: .user, text: "from another window")]
        )
        try AppState.chatStore.save([newer, elsewhere], for: connection)
        chat.delete(newer.id)
        XCTAssertEqual(AppState.chatStore.load(connection).conversations.map(\.title), ["Elsewhere"])
        XCTAssertEqual(chat.conversations.map(\.title), ["Elsewhere"])
    }

    func testUnreadableChatsAreSetAsideAndReported() throws {
        try TestDataDirectory.check()
        let connection = UUID()
        let file = AppState.chatStore.directory.appendingPathComponent("\(connection.uuidString).json")
        try FileManager.default.createDirectory(at: AppState.chatStore.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let chat = AIChatModel(connectionID: connection)
        XCTAssertTrue(chat.conversations.isEmpty)
        let error = try XCTUnwrap(chat.error)
        XCTAssertTrue(error.hasPrefix("Saved chats for this connection couldn't be read. They were moved to "), error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

/// Hands out samples in order, then fails.
private final class SampleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [MetricsSample]

    init(_ samples: [MetricsSample]) { self.samples = samples }

    func next() throws -> MetricsSample {
        try lock.withLock {
            guard !samples.isEmpty else { throw DatabaseError("No more samples") }
            return samples.removeFirst()
        }
    }
}
