import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaPostgres

final class SSHTunnelTests: XCTestCase {
    func testValidation() {
        XCTAssertNil(SSHConfig(host: "bastion.example.com", user: "app").problem)
        for host in ["-oProxyCommand=x", "a:b", "user@host", "a\nb", "a b", "a,b"] {
            XCTAssertNotNil(SSHConfig(host: host, user: "app").problem, host)
        }
        XCTAssertNotNil(SSHConfig(host: "bastion", port: 0, user: "app").problem)
        XCTAssertNotNil(SSHConfig(host: "bastion", user: "").problem)
    }

    func testArgumentsUseKeyAuthAndVerifiedHostKeys() {
        let args = SSHTunnel.arguments(
            SSHConfig(host: "bastion", user: "app"),
            localPort: 12345,
            targetHost: "db.internal",
            targetPort: 5432,
            timeout: 15
        )
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("PasswordAuthentication=no"))
        XCTAssertTrue(args.contains("ForwardAgent=no"))
        XCTAssertTrue(args.contains("127.0.0.1:12345:db.internal:5432"))
        // ClearAllForwardings would also drop the -L forward given here.
        XCTAssertFalse(args.contains("ClearAllForwardings=yes"))
        XCTAssertEqual(Array(args.prefix(2)), ["-F", "/dev/null"])
        XCTAssertEqual(Array(args.suffix(2)), ["--", "bastion"])
    }

    func testVerifiedTLSToAnIPAddressIsRefusedThroughSSH() async {
        let config = ConnectionConfig(
            kind: .postgres,
            host: "10.0.0.8",
            user: "app",
            tls: .verifyFull,
            ssh: SSHConfig(host: "bastion", user: "app")
        )
        do {
            let driver = try await DriverFactory.connect(config, password: nil)
            await driver.close()
            XCTFail("The certificate can't be checked against 10.0.0.8 through 127.0.0.1")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("host name"), error.localizedDescription)
        }
    }

    func testQuittingStopsOpenTunnels() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_TEST_SSH_DIR"] else {
            throw XCTSkip("TABULA_TEST_SSH_DIR not set")
        }
        let ssh = SSHConfig(host: "127.0.0.1", port: 52222, user: NSUserName(), identityFile: directory + "/client_key")
        let tunnel = try await SSHTunnel.open(
            ssh,
            targetHost: "127.0.0.1",
            targetPort: 55432,
            timeout: 5,
            knownHosts: directory + "/known_hosts"
        )
        SSHTunnel.terminateAll()
        try await Task.sleep(for: .milliseconds(500))
        let alive = await tunnel.isAlive
        XCTAssertFalse(alive)
        XCTAssertFalse(SSHTunnel.isListening(port: tunnel.localPort))
    }

    func testUntrustedHostKeyFails() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_TEST_SSH_DIR"] else {
            throw XCTSkip("TABULA_TEST_SSH_DIR not set")
        }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: empty, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let ssh = SSHConfig(host: "127.0.0.1", port: 52222, user: NSUserName(), identityFile: directory + "/client_key")
        do {
            let tunnel = try await SSHTunnel.open(
                ssh,
                targetHost: "127.0.0.1",
                targetPort: 55432,
                timeout: 5,
                knownHosts: empty
            )
            await tunnel.close()
            XCTFail("An unknown host key must not be accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("host key"), error.localizedDescription)
        }
    }

    func testDriverThroughTunnelClosesItWithTheConnection() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_TEST_SSH_DIR"] else {
            throw XCTSkip("TABULA_TEST_SSH_DIR not set")
        }
        let ssh = SSHConfig(host: "127.0.0.1", port: 52222, user: NSUserName(), identityFile: directory + "/client_key")
        let tunnel = try await SSHTunnel.open(
            ssh,
            targetHost: "127.0.0.1",
            targetPort: 55432,
            timeout: 5,
            knownHosts: directory + "/known_hosts"
        )
        let inner = try await PostgresDriver.connect(
            ConnectionConfig(kind: .postgres, port: tunnel.localPort, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let driver = TunneledDriver(inner, tunnel: tunnel)
        let result = try await driver.execute("SELECT current_user")
        XCTAssertEqual(result.rows, [["tabula"]])
        await driver.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(SSHTunnel.isListening(port: tunnel.localPort), "closing the driver must close the tunnel")
        let alive = await tunnel.isAlive
        XCTAssertFalse(alive)
    }

    func testTunnelToLocalPostgres() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_TEST_SSH_DIR"] else {
            throw XCTSkip("TABULA_TEST_SSH_DIR not set")
        }
        let ssh = SSHConfig(host: "127.0.0.1", port: 52222, user: NSUserName(), identityFile: directory + "/client_key")
        let tunnel = try await SSHTunnel.open(
            ssh,
            targetHost: "127.0.0.1",
            targetPort: 55432,
            timeout: 5,
            knownHosts: directory + "/known_hosts"
        )
        do {
            let driver = try await PostgresDriver.connect(
                ConnectionConfig(
                    kind: .postgres,
                    port: tunnel.localPort,
                    user: "tabula",
                    database: "tabula"
                ),
                password: "tabula"
            )
            let result = try await driver.execute("SELECT 42")
            XCTAssertEqual(result.rows, [["42"]])
            await driver.close()
            await tunnel.close()
        } catch {
            await tunnel.close()
            throw error
        }
    }
}
