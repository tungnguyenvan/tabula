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
        // An IPv6 address goes in brackets, or URLComponents gives no URL at all; the % before a zone (fe80::1%en0)
        // is written %25 (RFC 6874), as an unencoded one stops the app.
        if resolvedHost.contains(":"), !resolvedHost.contains(","), !resolvedHost.hasPrefix("[") {
            components.percentEncodedHost = "[\(resolvedHost.replacingOccurrences(of: "%", with: "%25"))]"
        } else {
            components.host = resolvedHost
        }
        components.port = kind == .mongodb && srv == true ? nil : port
        // URLComponents leaves ":" in a user name, where it would start the password.
        if !user.isEmpty {
            components.percentEncodedUser = user.addingPercentEncoding(withAllowedCharacters: Self.userCharacters)
        }
        if let password, !password.isEmpty {
            components.password = password
        }
        if !database.isEmpty {
            components.path = "/" + database
        }
        var parameters = tlsParameters
        if kind == .mongodb, let authSource, !authSource.isEmpty {
            parameters.append(URLQueryItem(name: "authSource", value: authSource))
        }
        if !parameters.isEmpty {
            components.queryItems = parameters
        }
        // A replica set lists its members, "a:27017,b:27017", which URLComponents won't take as a host.
        if kind == .mongodb, resolvedHost.contains(",") {
            let placeholder = "tabula.hosts.invalid"
            components.host = placeholder
            components.port = nil
            // Members without their own port use the connection's, as the driver does.
            let members = resolvedHost.split(separator: ",")
                .map { member -> String in
                    let text = member.trimmingCharacters(in: .whitespaces)
                    return text.contains(":") ? text : "\(text):\(port)"
                }
            return components.string?.replacingOccurrences(of: placeholder, with: members.joined(separator: ",")) ?? ""
        }
        return components.string ?? ""
    }

    private static let userCharacters = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@"))

    private var urlScheme: String {
        switch kind {
        case .postgres: "postgresql"
        case .mysql: "mysql"
        case .redis: tls == .disable ? "redis" : "rediss"
        case .sqlite: "file"
        case .mongodb: srv == true ? "mongodb+srv" : "mongodb"
        }
    }

    /// TLS settings in each client's own spelling; rediss:// and mongodb+srv:// already imply them.
    private var tlsParameters: [URLQueryItem] {
        // A seed list means TLS unless the URL says otherwise.
        if tls == .disable {
            return kind == .mongodb && srv == true ? [URLQueryItem(name: "tls", value: "false")] : []
        }
        switch kind {
        case .postgres: return [URLQueryItem(name: "sslmode", value: tls == .verifyFull ? "verify-full" : "require")]
        case .mysql: return [URLQueryItem(name: "ssl-mode", value: tls == .verifyFull ? "VERIFY_IDENTITY" : "REQUIRED")]
        case .mongodb:
            if srv == true {
                return tls == .verifyFull ? [] : [URLQueryItem(name: "tlsAllowInvalidCertificates", value: "true")]
            }
            return [URLQueryItem(name: "tls", value: "true")]
                + (tls == .verifyFull ? [] : [URLQueryItem(name: "tlsAllowInvalidCertificates", value: "true")])
        // rediss:// alone means a verified certificate, as in redis-cli and redis-py.
        case .redis: return tls == .verifyFull ? [] : [URLQueryItem(name: "ssl_cert_reqs", value: "none")]
        case .sqlite: return []
        }
    }
}
