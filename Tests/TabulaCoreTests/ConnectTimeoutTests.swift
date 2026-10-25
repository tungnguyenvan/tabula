import Darwin
import XCTest
@testable import TabulaCore

final class ConnectTimeoutTests: XCTestCase {
    /// A server that accepts TCP but never speaks the protocol must not hang the app.
    func testSilentServerTimesOut() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 4)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let started = Date()
        do {
            _ = try await DriverFactory.connect(ConnectionConfig(kind: .mysql, port: port, user: "x"), password: nil)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}

final class RefusedConnectionTests: XCTestCase {
    /// A server that isn't running must say so, every time, not report a cancellation.
    func testRefusedConnectionsReportTheRefusal() async throws {
        for _ in 0..<3 {
            do {
                _ = try await RedisDriver.connect(ConnectionConfig(kind: .redis, host: "127.0.0.1", port: 1), password: nil)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("refused"), error.localizedDescription)
            }
        }
    }
}
