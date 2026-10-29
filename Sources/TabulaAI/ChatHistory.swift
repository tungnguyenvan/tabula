import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates

/// One message of an AI chat: the user's, the assistant's, or a tool the assistant used.
public struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public struct ToolStep: Equatable, Codable, Sendable {
        public enum Status: String, Codable, Sendable {
            case running, awaitingApproval, done, denied, stopped
        }
        public var call: AgentToolCall
        public var status: Status
        public var result = ""

        public init(call: AgentToolCall, status: Status, result: String = "") {
            self.call = call
            self.status = status
            self.result = result
        }
    }

    public var id = UUID()
    public var role: Role
    /// For the assistant, the reply as the model wrote it, which may end in a tool request
    /// (`AgentProtocol.visibleText` is what is shown).
    public var text: String
    /// The model's reasoning, when the provider shares it.
    public var thinking = ""
    /// Seconds of reasoning before the answer began.
    public var thoughtFor: TimeInterval?
    /// Still arriving.
    public var streaming = false
    /// Gathering the schema, before the request goes out.
    public var preparing = false
    public var tool: ToolStep?

    public init(role: Role, text: String, streaming: Bool = false, preparing: Bool = false, tool: ToolStep? = nil) {
        self.role = role
        self.text = text
        self.streaming = streaming
        self.preparing = preparing
        self.tool = tool
    }

    // Files written by later versions may add fields; files from this one may lack the optional ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        thoughtFor = try c.decodeIfPresent(TimeInterval.self, forKey: .thoughtFor)
        tool = try? c.decodeIfPresent(ToolStep.self, forKey: .tool)
        // Nothing is still running in a saved conversation.
        if var step = tool, step.status == .running || step.status == .awaitingApproval {
            step.status = .stopped
            tool = step
        }
    }
}

public struct ChatConversation: Identifiable, Equatable, Codable, Sendable {
    public var id = UUID()
    public var title: String
    public var updated: Date
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), title: String, updated: Date = Date(), messages: [ChatMessage]) {
        self.id = id
        self.title = title
        self.updated = updated
        self.messages = messages
    }

    // A message this version can't read (a newer kind, a damaged entry) is skipped, not the whole conversation.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
        messages = (try c.decodeIfPresent([Lossy<ChatMessage>].self, forKey: .messages) ?? []).compactMap(\.value)
    }

    /// The first question, shortened, names the conversation.
    public static func title(for messages: [ChatMessage]) -> String {
        let question = messages.first { $0.role == .user }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !line.isEmpty else { return "New Chat" }
        return line.count > Defaults.AI.conversationTitleLength
            ? String(line.prefix(Defaults.AI.conversationTitleLength)) + "…" : line
    }
}

/// Saved AI conversations, one file per connection, in Application Support next to the connections.
public struct ChatStore: Sendable {
    public let directory: URL

    /// `base` is the folder that holds connections.json (nil: Application Support/Tabula).
    public init(base: URL? = nil) {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        directory = root.appendingPathComponent("Chats", isDirectory: true)
    }

    private func fileURL(_ connection: UUID) -> URL {
        directory.appendingPathComponent("\(connection.uuidString).json")
    }

    /// Newest first. Conversations that can't be read are skipped. A file that can't be read at all is moved
    /// aside (`….unreadable-<time>.json`) rather than overwritten by the next save.
    public func load(_ connection: UUID) -> [ChatConversation] {
        let url = fileURL(connection)
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let entries = try? Self.decoder.decode([Lossy<ChatConversation>].self, from: data) else {
            let aside = directory.appendingPathComponent("\(connection.uuidString).unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        return entries.compactMap(\.value).sorted { $0.updated > $1.updated }
    }

    /// Keeps the newest `Defaults.AI.savedConversations`; an empty list removes the file.
    public func save(_ conversations: [ChatConversation], for connection: UUID) throws {
        let kept = Array(conversations.sorted { $0.updated > $1.updated }.prefix(Defaults.AI.savedConversations))
        guard !kept.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL(connection))
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(kept).write(to: fileURL(connection), options: .atomic)
    }

    /// Removes a connection's conversations, when the connection is deleted.
    public func remove(_ connection: UUID) {
        try? FileManager.default.removeItem(at: fileURL(connection))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Decodes a value, or nil when it can't be read, so one bad element doesn't fail the whole list.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
