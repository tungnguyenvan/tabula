import XCTest

@testable import TabulaFoundation

final class ConnectionStringParserTests: XCTestCase {
    private func parse(_ text: String) throws -> (config: ConnectionConfig, password: String?) {
        try XCTUnwrap(ConnectionConfig.parse(connectionString: text), text)
    }

    func testURLsAndJDBC() throws {
        let (url, urlPassword) = try parse("  postgresql://app:s%3Fcret@db.example.com:6543/shop?sslmode=require\n")
        XCTAssertEqual([url.host, url.user, url.database], ["db.example.com", "app", "shop"])
        XCTAssertEqual(url.port, 6543)
        XCTAssertEqual(urlPassword, "s?cret")

        // JDBC gives the login as options.
        let (jdbc, jdbcPassword) = try parse(
            "jdbc:postgresql://db.example.com:5433/shop?user=app&password=p%26ss&ssl=true"
        )
        XCTAssertEqual(jdbc.kind, .postgres)
        XCTAssertEqual([jdbc.host, jdbc.user, jdbc.database], ["db.example.com", "app", "shop"])
        XCTAssertEqual(jdbc.port, 5433)
        XCTAssertEqual(jdbcPassword, "p&ss")
        XCTAssertEqual(jdbc.tls, .verifyFull)

        let (mysql, _) = try parse("JDBC:mysql://db.example.com/shop?user=app")
        XCTAssertEqual(mysql.kind, .mysql)
        XCTAssertEqual(mysql.port, 3306)
        // A login in the URL wins over one in the options.
        XCTAssertEqual(try parse("mysql://root:a@h/db?user=other&password=b").config.user, "root")
        XCTAssertEqual(try parse("mysql://root:a@h/db?user=other&password=b").password, "a")

        XCTAssertEqual(try parse("jdbc:sqlite:/Users/me/shop.db").config.filePath, "/Users/me/shop.db")
        XCTAssertEqual(try parse("jdbc:sqlite:/Users/me/shop.db").config.kind, .sqlite)
        XCTAssertNil(ConnectionConfig.parse(connectionString: "jdbc:sqlite::memory:"))
    }

    func testLibpqKeyValues() throws {
        let (config, password) = try parse(
            "host=db.example.com port=5433 dbname=shop user=app password='s3 cret' sslmode=verify-full"
        )
        XCTAssertEqual(config.kind, .postgres)
        XCTAssertEqual([config.host, config.database, config.user], ["db.example.com", "shop", "app"])
        XCTAssertEqual(config.port, 5433)
        XCTAssertEqual(config.tls, .verifyFull)
        // Quoted values hold spaces; a backslash escapes a quote.
        XCTAssertEqual(password, "s3 cret")
        XCTAssertEqual(try parse("host = db password = 'a b\\'c' user=x").password, "a b'c")
        XCTAssertEqual(try parse("dbname=shop user=app").config.host, Defaults.host)
        // An unquoted ";" means another format, and as that format it names no host.
        XCTAssertNil(ConnectionConfig.parse(connectionString: "host=db password=a;b user=x"))
    }

    func testSemicolonSeparated() throws {
        let (mysql, mysqlPassword) = try parse(
            "Server=db.example.com;Port=3307;Database=shop;Uid=app;Pwd=p@ss;SslMode=Required;"
        )
        XCTAssertEqual(mysql.kind, .mysql)
        XCTAssertEqual([mysql.host, mysql.database, mysql.user], ["db.example.com", "shop", "app"])
        XCTAssertEqual(mysql.port, 3307)
        XCTAssertEqual(mysql.tls, .require)
        XCTAssertEqual(mysqlPassword, "p@ss")

        // Npgsql
        let (postgres, postgresPassword) = try parse(
            "Host=db.example.com;Username=app;Password=\"a;b\"\"c\";Database=shop"
        )
        XCTAssertEqual(postgres.kind, .postgres)
        XCTAssertEqual(postgres.port, 5432)
        XCTAssertEqual(postgresPassword, "a;b\"c")

        // Keys with spaces, a port with the host, and a port that decides the type.
        let (spaced, _) = try parse("Data Source=db.example.com,5432; Initial Catalog=shop; User Id=app; Password=x")
        XCTAssertEqual(spaced.kind, .postgres)
        XCTAssertEqual([spaced.host, spaced.database, spaced.user], ["db.example.com", "shop", "app"])
        XCTAssertEqual(try parse("Server=10.0.0.5:3306;User=app").config.host, "10.0.0.5")
    }

    func testNotAConnectionString() {
        for text in [
            "", "db.example.com", "a=b", "SELECT 1; SELECT 2", "https://example.com", "name=x color=blue",
            "Server=db;Password=\"unclosed", "foo bar=baz",
        ] {
            XCTAssertNil(ConnectionConfig.parse(connectionString: text), text)
        }
    }
}
