import Foundation
import TabulaDrivers
import TabulaFoundation

/// How a console command that is still running can be ended from a second connection.
public enum RedisStop: Equatable, Sendable {
    /// SCRIPT KILL: a Lua script (EVAL, EVALSHA). Redis serves nobody until the script has run for its
    /// busy-reply-threshold (5 seconds by default), so the kill takes effect from then. Redis can't say whose
    /// script is running, so on a shared server this ends whichever one is; a script that has written can't be
    /// killed this way.
    case script
    /// FUNCTION KILL: a function (FCALL), with the same limits as a script.
    case function
    /// CLIENT UNBLOCK: a blocking command (BLPOP, XREAD BLOCK …) of the console's own connection.
    case unblock
    /// Anything else runs inside the server to the end.
    case unsupported

    public init(for arguments: [[UInt8]]) {
        let name = arguments.first.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? ""
        switch name {
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO":
            self = .script
        case "FCALL", "FCALL_RO":
            self = .function
        case "BLPOP", "BRPOP", "BZPOPMIN", "BZPOPMAX", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZMPOP", "WAIT", "WAITAOF":
            self = .unblock
        case "XREAD", "XREADGROUP":
            let blocks = arguments.contains { String(decoding: $0, as: UTF8.self).uppercased() == "BLOCK" }
            self = blocks ? .unblock : .unsupported
        default:
            self = .unsupported
        }
    }
}

extension RedisDriver {
    /// Ends this connection's running command as `stop` says, from a short-lived connection of its own; the
    /// command then returns the server's error. Returns why it couldn't, or nil when the server took the request.
    public func stopRunningCommand(_ stop: RedisStop, config: ConnectionConfig, password: String?) async -> String? {
        let arguments: [String]
        switch stop {
        case .script:
            arguments = ["SCRIPT", "KILL"]
        case .function:
            arguments = ["FUNCTION", "KILL"]
        case .unblock:
            guard let clientID else {
                return "The server didn't give this connection's client id, so it can't be unblocked."
            }
            arguments = ["CLIENT", "UNBLOCK", String(clientID), "ERROR"]
        case .unsupported:
            return "Redis can't stop this command; it runs to the end."
        }
        // A server busy with a script refuses SELECT, and these requests don't need a database.
        var controlConfig = config
        controlConfig.database = ""
        let control: RedisDriver
        do {
            control = try await RedisDriver.connect(controlConfig, password: password)
        } catch {
            return error.localizedDescription
        }
        defer { Task { await control.close() } }
        do {
            switch try await control.send(arguments.map { Array($0.utf8) }) {
            case .error(let message):
                return message
            case .integer(0):
                return "The command had already finished."
            default:
                return nil
            }
        } catch {
            return error.localizedDescription
        }
    }
}
