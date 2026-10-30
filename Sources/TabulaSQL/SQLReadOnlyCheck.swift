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
    /// Functions that act on the server or read its files, even in a read-only transaction. Names only, never
    /// prefixes, so catalog views such as `pg_file_settings` and `pg_replication_slots` stay readable.
    private static let blockedFunctions: Set<String> = sqlRunners.union(serverActions).union(serverFiles).union(locks)

    /// Run SQL given as text, where the words of that SQL are a string this check doesn't look into.
    private static let sqlRunners: Set<String> = [
        "QUERY_TO_XML", "QUERY_TO_XMLSCHEMA", "QUERY_TO_XML_AND_XMLSCHEMA", "TS_STAT", "TS_REWRITE",
        // tablefunc
        "CROSSTAB", "CROSSTAB2", "CROSSTAB3", "CROSSTAB4", "CONNECTBY",
        // dblink
        "DBLINK", "DBLINK_EXEC", "DBLINK_CONNECT", "DBLINK_CONNECT_U", "DBLINK_OPEN", "DBLINK_FETCH",
        "DBLINK_SEND_QUERY", "DBLINK_GET_RESULT",
    ]

    /// Change the server, its sessions or its statistics; none of it is undone by rolling back.
    private static let serverActions: Set<String> = [
        "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "SET_CONFIG", "PG_SLEEP",
        "PG_SLEEP_FOR", "PG_SLEEP_UNTIL", "PG_SWITCH_WAL", "PG_CREATE_RESTORE_POINT", "PG_LOGICAL_EMIT_MESSAGE",
        "PG_PROMOTE", "PG_WAL_REPLAY_PAUSE", "PG_WAL_REPLAY_RESUME", "PG_BACKUP_START", "PG_BACKUP_STOP",
        "PG_LOG_BACKEND_MEMORY_CONTEXTS", "PG_IMPORT_SYSTEM_COLLATIONS",
        "PG_STAT_RESET", "PG_STAT_RESET_SHARED", "PG_STAT_RESET_SINGLE_TABLE_COUNTERS",
        "PG_STAT_RESET_SINGLE_FUNCTION_COUNTERS", "PG_STAT_RESET_SLRU", "PG_STAT_RESET_REPLICATION_SLOT",
        "PG_STAT_RESET_SUBSCRIPTION_STATS", "PG_STAT_STATEMENTS_RESET",
        "PG_CREATE_PHYSICAL_REPLICATION_SLOT", "PG_CREATE_LOGICAL_REPLICATION_SLOT", "PG_DROP_REPLICATION_SLOT",
        "PG_COPY_PHYSICAL_REPLICATION_SLOT", "PG_COPY_LOGICAL_REPLICATION_SLOT", "PG_REPLICATION_SLOT_ADVANCE",
        "PG_REPLICATION_ORIGIN_CREATE", "PG_REPLICATION_ORIGIN_DROP", "PG_REPLICATION_ORIGIN_ADVANCE",
        "PG_REPLICATION_ORIGIN_SESSION_SETUP",
        "SLEEP", "BENCHMARK", "SOURCE_POS_WAIT", "MASTER_POS_WAIT", "WAIT_FOR_EXECUTED_GTID_SET",
        "LOAD_EXTENSION", "FTS3_TOKENIZER",
        // Index maintenance and WAL records, which a read-only transaction still allows.
        "BRIN_SUMMARIZE_NEW_VALUES", "BRIN_SUMMARIZE_RANGE", "BRIN_DESUMMARIZE_RANGE", "GIN_CLEAN_PENDING_LIST",
        "PG_LOG_STANDBY_SNAPSHOT",
        // PostgreSQL 18's planner statistics and per-backend counters.
        "PG_RESTORE_RELATION_STATS", "PG_RESTORE_ATTRIBUTE_STATS", "PG_CLEAR_RELATION_STATS",
        "PG_CLEAR_ATTRIBUTE_STATS", "PG_STAT_RESET_BACKEND_STATS",
        // Sequences move on whether or not the transaction commits.
        "NEXTVAL", "SETVAL",
    ]

    /// Read or write files on the database server's machine.
    private static let serverFiles: Set<String> = [
        "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_STAT_FILE", "PG_LS_DIR", "PG_LS_LOGDIR", "PG_LS_WALDIR",
        "PG_LS_TMPDIR", "PG_LS_ARCHIVE_STATUSDIR", "PG_LS_LOGICALMAPDIR", "PG_LS_LOGICALSNAPDIR", "PG_LS_REPLSLOTDIR",
        "LO_IMPORT", "LO_EXPORT", "LO_UNLINK",
        // adminpack
        "PG_FILE_WRITE", "PG_FILE_RENAME", "PG_FILE_UNLINK", "PG_FILE_SYNC", "PG_LOGDIR_LS",
        "LOAD_FILE", "READFILE", "WRITEFILE",
    ]

    /// Advisory locks; session locks outlive the rolled-back transaction the assistant's statement runs in.
    private static let locks: Set<String> = [
        "PG_ADVISORY_LOCK", "PG_ADVISORY_LOCK_SHARED", "PG_ADVISORY_XACT_LOCK", "PG_ADVISORY_XACT_LOCK_SHARED",
        "PG_TRY_ADVISORY_LOCK", "PG_TRY_ADVISORY_LOCK_SHARED", "PG_TRY_ADVISORY_XACT_LOCK",
        "PG_TRY_ADVISORY_XACT_LOCK_SHARED", "PG_ADVISORY_UNLOCK", "PG_ADVISORY_UNLOCK_SHARED", "PG_ADVISORY_UNLOCK_ALL",
        "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS",
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
        // U&"…" names with their own escape character (PostgreSQL) spell a name without writing it out.
        if tokens.contains(where: { $0.keyword == "UESCAPE" }) { return "Write names without Unicode escapes." }
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
