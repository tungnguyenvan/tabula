import BSON
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Decides whether a shell command the assistant wants to run only reads: collection reads and a few database
/// reads, without stages that write or operators that run code on the server.
enum MongoReadOnlyCheck {
    private static let readMethods: Set<String> = [
        "find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount",
        "distinct", "getIndexes", "count",
    ]
    private static let databaseReadMethods: Set<String> = [
        "getCollectionNames", "getCollectionInfos", "stats", "version", "getName",
    ]

    /// Why the command can't run, or nil when it only reads.
    static func violation(_ text: String) -> String? {
        let statements = MongoSplitter.statements(in: text)
        guard statements.count == 1 else {
            return "Run one command at a time."
        }
        guard let statement = try? MongoStatement.parse(text) else {
            return "The command couldn't be read."
        }
        switch statement.target {
        case .show(let what):
            return ["dbs", "databases", "collections", "tables"].contains(what)
                ? nil : "Only show dbs and show collections can run."
        case .use:
            return "use changes the database; name the collection instead."
        case .database:
            guard let method = statement.method, databaseReadMethods.contains(method) else {
                return "Only collection reads (find, aggregate, countDocuments, distinct) can run."
            }
            return nil
        case .collection:
            guard let method = statement.method, readMethods.contains(method) else {
                return
                    "Only find, findOne, aggregate, countDocuments, estimatedDocumentCount, distinct and getIndexes can run."
            }
            // The parsed keys, so escapes ("\u0024out") can't hide a stage.
            if let key = statement.calls.flatMap(\.arguments).lazy.compactMap(blockedKey).first {
                return
                    "\(key) \(key == "$out" || key == "$merge" ? "writes to a collection" : "runs code on the server"), so the command can't run."
            }
            return nil
        }
    }

    /// Stages that write, and operators that run JavaScript on the server.
    private static let blockedKeys: Set<String> = ["$out", "$merge", "$where", "$function", "$accumulator"]

    private static func blockedKey(in value: Primitive) -> String? {
        guard let document = value as? Document else { return nil }
        for pair in document.pairs {
            if blockedKeys.contains(pair.key) {
                return pair.key
            }
            if let found = blockedKey(in: pair.value) {
                return found
            }
        }
        return nil
    }
}
