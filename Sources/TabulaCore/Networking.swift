import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Connection plumbing shared by the network drivers.
extension ConnectionConfig {
    var resolvedHost: String { host.isEmpty ? Defaults.host : host }

    var timeout: Double { connectTimeout ?? Defaults.connectTimeout }

    /// The client TLS settings for this connection, or nil for plain TCP.
    func tlsConfiguration() -> TLSConfiguration? {
        switch tls {
        case .disable:
            return nil
        case .require:
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            return configuration
        case .verifyFull:
            return .makeClientConfiguration()
        }
    }

    /// Hostname for SNI and certificate checks; an IP address must not be sent as SNI.
    func serverName(usingTLS: Bool) -> String? {
        usingTLS && !isIPAddress(resolvedHost) ? resolvedHost : nil
    }

    /// Resolves the host off the caller's executor (it blocks), within the connect timeout.
    func resolveAddress() async throws -> SocketAddress {
        let host = resolvedHost, port = port
        return try await withTimeout(seconds: timeout, "Resolving \(host)") {
            try await Task.detached { try SocketAddress.makeAddressResolvingHost(host, port: port) }.value
        }
    }
}

func isIPAddress(_ host: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
}
