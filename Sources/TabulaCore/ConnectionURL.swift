import Foundation

extension ConnectionConfig {
    /// The connection as a URL other tools accept, e.g. `postgresql://user@host:5432/db?sslmode=require`.
    /// The password is left out unless given.
    public func url(password: String? = nil) -> String {
        if kind == .sqlite {
            return URL(fileURLWithPath: filePath).absoluteString
        }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = resolvedHost
        components.port = port
        if !user.isEmpty { components.user = user }
        if let password, !password.isEmpty { components.password = password }
        let path = kind == .redis ? (database.isEmpty ? "" : database) : database
        if !path.isEmpty { components.path = "/" + path }
        if let parameter = tlsParameter { components.queryItems = [parameter] }
        return components.string ?? ""
    }

    private var urlScheme: String {
        switch kind {
        case .postgres: "postgresql"
        case .mysql: "mysql"
        case .redis: tls == .disable ? "redis" : "rediss"
        case .sqlite: "file"
        }
    }

    /// TLS settings in each client's own spelling; rediss:// already says it for Redis.
    private var tlsParameter: URLQueryItem? {
        guard tls != .disable else { return nil }
        switch kind {
        case .postgres: return URLQueryItem(name: "sslmode", value: tls == .verifyFull ? "verify-full" : "require")
        case .mysql: return URLQueryItem(name: "ssl-mode", value: tls == .verifyFull ? "VERIFY_IDENTITY" : "REQUIRED")
        case .redis, .sqlite: return nil
        }
    }
}
