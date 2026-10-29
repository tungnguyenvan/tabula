import Foundation

extension ConnectionConfig {
    /// A connection read from a URL, as other tools write them: `postgresql://user:pass@host:5432/db?sslmode=require`,
    /// `mysql://`, `redis://` / `rediss://`, `mongodb://` / `mongodb+srv://`, `file:///path.sqlite`, and the URLs
    /// TablePlus copies (with `name`, `env` and `tLSMode`). The user name and password are percent-decoded once,
    /// as the URL standard says. Nil when the text isn't a connection URL.
    public static func parse(url text: String) -> (config: ConnectionConfig, password: String?)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = text.range(of: "://") else { return nil }
        let scheme = text[..<separator.lowerBound].lowercased()
        var rest = Substring(text[separator.upperBound...])

        var config: ConnectionConfig
        switch scheme {
        case "postgresql", "postgres": config = ConnectionConfig(kind: .postgres)
        case "mysql", "mariadb": config = ConnectionConfig(kind: .mysql)
        case "redis": config = ConnectionConfig(kind: .redis)
        case "rediss": config = ConnectionConfig(kind: .redis, tls: .verifyFull)
        case "mongodb": config = ConnectionConfig(kind: .mongodb)
        case "mongodb+srv": config = ConnectionConfig(kind: .mongodb, tls: .verifyFull, srv: true)
        case "file", "sqlite", "sqlite3":
            var path = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            // file://localhost/path names the same file as file:///path.
            if path.lowercased().hasPrefix("localhost/") { path.removeFirst("localhost".count) }
            let decoded = path.removingPercentEncoding ?? path
            guard !decoded.isEmpty else { return nil }
            return (ConnectionConfig(kind: .sqlite, filePath: decoded.hasPrefix("/") ? decoded : "/" + decoded), nil)
        default:
            return nil
        }

        // Passwords often hold raw "@", "?", "#" or "/" (they should be escaped but often aren't), while a host
        // holds none. So the user part ends at the last "@" before the first "/" that follows an "@", and the
        // path, query and fragment are looked for after it.
        let firstAt = rest.firstIndex(of: "@")
        let at = firstAt.flatMap { first in
            let limit = rest[first...].firstIndex(of: "/") ?? rest.endIndex
            return rest[..<limit].lastIndex(of: "@")
        }
        let afterUser = at.map { rest.index(after: $0) } ?? rest.startIndex
        if let hash = rest[afterUser...].firstIndex(of: "#") { rest = rest[..<hash] }
        var query = Substring("")
        if let mark = rest[afterUser...].firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
        }
        let slash = rest[afterUser...].firstIndex(of: "/")
        let authorityEnd = slash ?? rest.endIndex
        var path = slash.map { String(rest[rest.index(after: $0)...]) } ?? ""
        while path.hasSuffix("/") { path.removeLast() }

        var password: String?
        if let at {
            let userInfo = rest[..<at]
            if let colon = userInfo.firstIndex(of: ":") {
                config.user = Self.decoded(userInfo[..<colon])
                password = Self.decoded(userInfo[userInfo.index(after: colon)...])
            } else {
                config.user = Self.decoded(userInfo)
            }
        }

        let authority = String(rest[afterUser..<authorityEnd])
        if config.kind == .mongodb && authority.contains(",") {
            config.host = authority
        } else if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            // An IPv6 address: [::1]:5432
            config.host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":"), let port = Int(after.dropFirst()), Self.ports.contains(port) { config.port = port }
        } else if let colon = authority.lastIndex(of: ":"), let port = Int(authority[authority.index(after: colon)...]),
            Self.ports.contains(port)
        {
            config.host = String(authority[..<colon])
            config.port = port
        } else {
            config.host = authority
        }
        if config.host.isEmpty {
            config.host = Defaults.host
        }
        config.database = Self.decoded(Substring(path))

        var options = Options()
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = Self.decoded(pair[0]).lowercased()
            let value = pair.count > 1 ? Self.decoded(pair[1]) : ""
            Self.apply(key, value, to: &config, options: &options)
        }
        // Skipping certificate checks only weakens TLS that is on, whatever the order of the options.
        if options.insecure && config.tls == .verifyFull {
            config.tls = .require
        }
        return (config, password ?? options.password)
    }

    static let ports = 1...65535

    /// Options whose meaning depends on others in the same URL, and credentials given as options (JDBC).
    struct Options {
        var insecure = false
        var password: String?
    }

    private static func decoded(_ text: Substring) -> String {
        String(text).removingPercentEncoding ?? String(text)
    }

    /// One query option; unknown ones are ignored, as other clients do.
    static func apply(_ key: String, _ value: String, to config: inout ConnectionConfig, options: inout Options) {
        let lowered = value.lowercased()
        let on = ["1", "true", "yes", "on"].contains(lowered)
        switch key {
        case "sslmode", "ssl-mode":
            switch lowered {
            case "disable", "disabled", "allow": config.tls = .disable
            case "require", "required", "no-verify": config.tls = .require
            case "verify-ca", "verify-full", "verify_ca", "verify_identity": config.tls = .verifyFull
            // "prefer" falls back to plain text when the server has no TLS, which Tabula doesn't do: the scheme
            // decides, as for values Tabula doesn't know.
            default: break
            }
        case "ssl", "tls":
            if !on { config.tls = .disable } else if config.tls == .disable { config.tls = .verifyFull }
        case "tlsallowinvalidcertificates", "tlsinsecure":
            options.insecure = on
        case "sslverify":
            options.insecure = !on
        case "ssl_cert_reqs":
            options.insecure = lowered == "none"
        case "user", "username":
            // JDBC URLs give the login as options: jdbc:postgresql://host/db?user=app&password=secret
            if config.user.isEmpty {
                config.user = value
            }
        case "password":
            options.password = value
        case "authsource":
            config.authSource = value.isEmpty ? nil : value
        case "name":
            if !value.isEmpty {
                config.name = value
            }
        case "env":
            switch lowered {
            case "local": config.tag = .local
            case "development", "dev", "testing", "test": config.tag = .development
            case "staging": config.tag = .staging
            case "production", "prod": config.tag = .production
            default: break
            }
        case "tlsmode":
            // TablePlus: 0 is off, other values turn TLS on.
            config.tls = value == "0" ? .disable : .require
        default:
            break
        }
    }
}

/// Passwords that still hold URL escapes: some dashboards show a password ready for a URL, with `?` as `%3F`,
/// and typed into a password field as it is, the server sees a different password.
public enum PasswordEscapes {
    /// The password with its `%xx` escapes decoded once, or nil when it has none. Decoding once is what a URL
    /// does; a password escaped twice needs a second Decode, so a real `%` in a password is never lost silently.
    /// A `%` that starts no escape stays as it is.
    public static func decoded(_ password: String) -> String? {
        let bytes = Array(password.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var escapes = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"),
                let high = hexValue(bytes, index + 1), let low = hexValue(bytes, index + 2)
            {
                output.append(high << 4 | low)
                index += 3
                escapes += 1
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        guard escapes > 0 else { return nil }
        return String(bytes: output, encoding: .utf8)
    }

    private static func hexValue(_ bytes: [UInt8], _ index: Int) -> UInt8? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return bytes[index] - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return bytes[index] - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return bytes[index] - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The error's message, with a note when the login failed and the password looks escaped.
    public static func message(for error: any Error, password: String?) -> String {
        let message = error.localizedDescription
        guard let password, decoded(password) != nil else {
            return message
        }
        let lowered = message.lowercased()
        let loginFailures = [
            "authentication failed", "wrongpass", "access denied", "invalid username-password", "auth failed",
        ]
        guard loginFailures.contains(where: lowered.contains) else {
            return message
        }
        return message + " The password contains URL escapes such as %3F (which stands for ?). If you copied it "
            + "from a URL or a dashboard, edit the connection and click Decode."
    }
}
