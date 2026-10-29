import Foundation
import TabulaFoundation

/// Decides whether a SQL statement the assistant wants to run only reads. This is the first check; the agent's
/// own connection is also read-only where the server supports it (`DatabaseCatalog.prepareReadOnlySession`).
public enum SQLReadOnlyCheck {

    private static let firstWords: Set<String> = [
        "SELECT", "WITH", "EXPLAIN", "SHOW", "DESCRIBE", "DESC", "VALUES", "TABLE",
    ]
    private static let writingWords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "CREATE", "DROP", "ALTER", "TRUNCATE", "RENAME",
        "GRANT", "REVOKE", "COPY", "CALL", "DO", "LOCK", "UNLOCK", "VACUUM", "ANALYZE", "REINDEX", "CLUSTER", "ATTACH",
        "DETACH", "SET", "RESET", "PRAGMA", "LOAD", "HANDLER", "PREPARE", "EXECUTE", "DEALLOCATE",
        "LISTEN", "NOTIFY", "REFRESH", "IMPORT", "OUTFILE", "DUMPFILE", "KILL", "SHUTDOWN", "BEGIN", "COMMIT",
        "ROLLBACK",
        "SAVEPOINT", "RELEASE", "START",
    ]
    /// Functions that act on the server or read its files, even in a read-only transaction.
    private static let blockedFunctions: Set<String> = [
        "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "SET_CONFIG", "PG_SLEEP",
        "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_LS_DIR", "PG_STAT_FILE", "LO_IMPORT", "LO_EXPORT", "LO_UNLINK",
        "DBLINK", "DBLINK_EXEC", "PG_ADVISORY_LOCK", "PG_TRY_ADVISORY_LOCK", "SLEEP", "BENCHMARK", "LOAD_FILE",
        "GET_LOCK", "RELEASE_LOCK", "LOAD_EXTENSION", "READFILE", "WRITEFILE",
    ]

    /// Why the statement can't run, or nil when it only reads.
    public static func violation(_ statement: String, flavor: SQLFlavor) -> String? {
        let statements = SQLSplitter.split(statement, flavor: flavor)
        guard statements.count == 1 else {
            return "Run one statement at a time."
        }
        let tokens = SQLLexer.tokens(statement, flavor: flavor)
        // Where Tabula's lexer and the server could read the text differently, it isn't run: comments (MySQL
        // runs /*! … */ and doesn't take --x as one) and backslashes (escape rules differ by server and setting).
        if tokens.contains(where: { $0.kind == .comment }) { return "Write the statement without comments." }
        if statement.contains("\\") { return "Write the statement without backslashes." }
        let words = tokens.filter { $0.kind == .word }
        guard let first = words.first?.keyword, firstWords.contains(first) else {
            return "Only SELECT, WITH, EXPLAIN, SHOW and DESCRIBE statements can run; this one may change data."
        }
        if let word = words.first(where: { writingWords.contains($0.keyword) }) {
            return "\(word.keyword) can change data or the session, so the statement can't run."
        }
        // SELECT … INTO makes a table or a file and FOR UPDATE / FOR SHARE locks rows; inside parentheses the
        // words mean something else (`substring(x FROM 1 FOR 3)`).
        var depth = 0
        for token in SQLLexer.tokens(statement, flavor: flavor) {
            if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
            if depth == 0, token.keyword == "INTO" || token.keyword == "FOR" {
                return "\(token.keyword) at the top level writes or locks rows, so the statement can't run."
            }
        }
        // A quoted name ("set_config", `GET_LOCK`) calls the same function.
        let names = tokens.compactMap { token -> String? in
            switch token.kind {
            case .word: return token.keyword
            case .quotedIdentifier: return String(token.text.dropFirst().dropLast()).uppercased()
            default: return nil
            }
        }
        if let name = names.first(where: { blockedFunctions.contains($0) }) {
            return "\(name.lowercased()) acts on the server, so the statement can't run."
        }
        return nil
    }
}
