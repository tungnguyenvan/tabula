import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaMongo
import TabulaMySQL
import TabulaPostgres
import TabulaSQLite

public enum DriverFactory {
    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> any DatabaseDriver {
        if let ssh = config.ssh { return try await connectThroughSSH(config, ssh: ssh, password: password) }
        switch config.kind {
        case .sqlite:
            return try SQLiteDriver(path: config.filePath)
        case .postgres:
            return try await PostgresDriver.connect(config, password: password)
        case .mysql:
            return try await MySQLDriver.connect(config, password: password)
        case .mongodb:
            return try await MongoDriver.connect(config, password: password)
        case .redis:
            throw DatabaseError("Redis connections use RedisDriver, not the SQL driver interface.")
        }
    }
}

extension DriverFactory {
    /// Opens the database through an SSH tunnel that lives as long as the returned driver. The driver connects to
    /// the tunnel's local port, while TLS still checks the database's real host name.
    static func connectThroughSSH(
        _ config: ConnectionConfig,
        ssh: SSHConfig,
        password: String?
    ) async throws -> any DatabaseDriver {
        guard config.kind == .postgres || config.kind == .mysql else {
            throw DatabaseError("SSH tunnels are available for PostgreSQL and MySQL connections.")
        }
        // Through the tunnel the socket's address is 127.0.0.1, so a certificate could only be checked against a
        // host name, never against the database's IP address.
        if config.tls == .verifyFull && isIPAddress(config.resolvedHost) {
            throw DatabaseError(
                "Verify certificate needs the database's host name when connecting over SSH, not an IP address. Enter the name its certificate was issued for, or set TLS to Required."
            )
        }
        // The connect timeout covers the database login; the tunnel gets its own, so a slow SSH server and a slow
        // database don't share one budget.
        let tunnel = try await SSHTunnel.open(
            ssh,
            targetHost: config.resolvedHost,
            targetPort: config.port,
            timeout: config.timeout
        )
        var local = config
        local.ssh = nil
        local.host = "127.0.0.1"
        local.port = tunnel.localPort
        do {
            let driver: any DatabaseDriver =
                config.kind == .postgres
                ? try await PostgresDriver.connect(
                    local,
                    password: password,
                    tlsServerName: config.serverName(usingTLS: config.tls != .disable)
                )
                : try await MySQLDriver.connect(
                    local,
                    password: password,
                    tlsServerName: config.serverName(usingTLS: config.tls != .disable)
                )
            return TunneledDriver(driver, tunnel: tunnel)
        } catch {
            await tunnel.close()
            throw error
        }
    }
}
