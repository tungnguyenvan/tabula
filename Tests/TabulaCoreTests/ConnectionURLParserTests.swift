import XCTest
@testable import TabulaCore

final class ConnectionURLParserTests: XCTestCase {
    func testPostgresWithEscapedPassword() throws {
        // The password "p?|<[@x" as a URL writes it.
        let (config, password) = try XCTUnwrap(ConnectionConfig.parse(url: "postgresql://admin:p%3F%7C%3C%5B%40x@db.example.com:6543/payment?sslmode=require"))
        XCTAssertEqual(config.kind, .postgres)
        XCTAssertEqual(config.user, "admin")
        XCTAssertEqual(password, "p?|<[@x")
        XCTAssertEqual(config.host, "db.example.com")
        XCTAssertEqual(config.port, 6543)
        XCTAssertEqual(config.database, "payment")
        XCTAssertEqual(config.tls, .require)
    }

    func testPasswordEscapedTwiceInAURLDecodesOnce() throws {
        // A password field holding "a%3Fb" goes into a URL as "a%253Fb"; reading the URL gives the field back.
        let (_, password) = try XCTUnwrap(ConnectionConfig.parse(url: "postgres://u:a%253Fb@h/db"))
        XCTAssertEqual(password, "a%3Fb")
        XCTAssertEqual(PasswordEscapes.decoded(try XCTUnwrap(password)), "a?b")
    }

    func testRawAtSignInPassword() throws {
        let (config, password) = try XCTUnwrap(ConnectionConfig.parse(url: "mysql://root:pa@ss@localhost/shop"))
        XCTAssertEqual(config.kind, .mysql)
        XCTAssertEqual(password, "pa@ss")
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, DatabaseKind.mysql.defaultPort)
    }

    func testTablePlusRedisURL() throws {
        let url = "redis://:secret@10.0.0.5:7000?statusColor=007F3D&env=production&name=pay&tLSMode=0&usePrivateKey=false"
        let (config, password) = try XCTUnwrap(ConnectionConfig.parse(url: url))
        XCTAssertEqual(config.kind, .redis)
        XCTAssertEqual(config.user, "")
        XCTAssertEqual(password, "secret")
        XCTAssertEqual(config.host, "10.0.0.5")
        XCTAssertEqual(config.port, 7000)
        XCTAssertEqual(config.name, "pay")
        XCTAssertEqual(config.tag, .production)
        XCTAssertEqual(config.tls, .disable)
    }

    func testRedissAndDatabaseIndex() throws {
        let (config, password) = try XCTUnwrap(ConnectionConfig.parse(url: "rediss://cache.example.com/3"))
        XCTAssertEqual(config.tls, .verifyFull)
        XCTAssertEqual(config.database, "3")
        XCTAssertNil(password)
    }

    func testMongoSeedListAndOptions() throws {
        let (config, _) = try XCTUnwrap(ConnectionConfig.parse(url: "mongodb+srv://app:pw@cluster0.example.mongodb.net/shop?authSource=admin&retryWrites=true"))
        XCTAssertEqual(config.kind, .mongodb)
        XCTAssertEqual(config.srv, true)
        XCTAssertEqual(config.host, "cluster0.example.mongodb.net")
        XCTAssertEqual(config.authSource, "admin")
        XCTAssertEqual(config.database, "shop")
        XCTAssertEqual(config.tls, .verifyFull)

        let (replicaSet, _) = try XCTUnwrap(ConnectionConfig.parse(url: "mongodb://a:27017,b:27018/?tls=true&tlsAllowInvalidCertificates=true"))
        XCTAssertEqual(replicaSet.host, "a:27017,b:27018")
        XCTAssertEqual(replicaSet.tls, .require)
    }

    func testIPv6AndSQLite() throws {
        let (config, _) = try XCTUnwrap(ConnectionConfig.parse(url: "postgresql://u@[::1]:5433/db"))
        XCTAssertEqual(config.host, "::1")
        XCTAssertEqual(config.port, 5433)

        let (file, _) = try XCTUnwrap(ConnectionConfig.parse(url: "file:///Users/me/My%20Data.sqlite"))
        XCTAssertEqual(file.kind, .sqlite)
        XCTAssertEqual(file.filePath, "/Users/me/My Data.sqlite")
    }

    func testNotAURL() {
        XCTAssertNil(ConnectionConfig.parse(url: "db.example.com"))
        XCTAssertNil(ConnectionConfig.parse(url: "https://example.com"))
        XCTAssertNotNil(ConnectionConfig.parse(url: "postgres://u@h/db?=&sslmode"))
    }

    func testRoundTripThroughURL() throws {
        let config = ConnectionConfig(kind: .postgres, host: "db.example.com", port: 5432, user: "admin", database: "payment", tls: .require)
        let password = "5g?-|C(*<[8%"
        let (parsed, parsedPassword) = try XCTUnwrap(ConnectionConfig.parse(url: config.url(password: password)))
        XCTAssertEqual(parsedPassword, password)
        XCTAssertEqual(parsed.host, config.host)
        XCTAssertEqual(parsed.user, config.user)
        XCTAssertEqual(parsed.database, config.database)
        XCTAssertEqual(parsed.tls, config.tls)
    }

    func testPasswordEscapes() {
        XCTAssertNil(PasswordEscapes.decoded("plain-password"))
        XCTAssertNil(PasswordEscapes.decoded("100%"))
        XCTAssertEqual(PasswordEscapes.decoded("a%3Fb%7C"), "a?b|")
        // Escaped twice: each Decode removes one layer.
        XCTAssertEqual(PasswordEscapes.decoded("a%253F"), "a%3F")
        // A lone % or one before non-hex stays; the escapes around it still decode.
        XCTAssertEqual(PasswordEscapes.decoded("50%off%3F%"), "50%off?%")
        XCTAssertEqual(PasswordEscapes.decoded("caf%C3%A9"), "café")
        // Escapes that aren't UTF-8 text can't be the real password.
        XCTAssertNil(PasswordEscapes.decoded("%FF"))

        struct Failure: LocalizedError { let errorDescription: String? }
        let failed = Failure(errorDescription: "password authentication failed for user \"admin\"")
        XCTAssertTrue(PasswordEscapes.message(for: failed, password: "a%3F").contains("URL escapes"))
        XCTAssertEqual(PasswordEscapes.message(for: failed, password: "a?"), failed.errorDescription)
        let refused = Failure(errorDescription: "Connection refused")
        XCTAssertEqual(PasswordEscapes.message(for: refused, password: "a%3F"), "Connection refused")
        XCTAssertTrue(PasswordEscapes.message(for: Failure(errorDescription: "WRONGPASS invalid username-password pair"), password: "%40").contains("Decode"))
    }
}
