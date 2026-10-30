import BSON
import XCTest

@testable import TabulaMongo
@testable import TabulaSQL

/// Beautify changes only layout: the script's tokens other than whitespace are the same before and after, and a
/// second beautify changes nothing.
final class FormatterInvariantTests: XCTestCase {
    private let scripts: [(SQLFlavor, String)] = [
        (.postgres, "select a,b from t where x='select from where' and y=$$ a;b $$ order by 1"),
        (
            .postgres,
            "SELECT E'it\\'s', \"Mixed Case\".col -- trailing comment\nFROM s.\"T\" WHERE n::int >= 5 /* block */ LIMIT 3"
        ),
        (
            .postgres,
            "with x as (select 1 as a union all select 2) select * from x join y on x.a=y.a left join z using (a)"
        ),
        (.postgres, "insert into t(a,b) values (1,'x'),(2,'y') on conflict (a) do update set b=excluded.b returning *"),
        (
            .postgres,
            "select case when a>1 then 'big' else 'small' end, count(*) filter (where b) from t group by 1 having count(*)>2"
        ),
        (.postgres, "create function f() returns int as $body$ begin return 1; end $body$ language plpgsql"),
        (.mysql, "SELECT `select`, 'a\\'b', \"double\" FROM `db`.`t` WHERE x LIKE 'a%' # note\nAND y = 2"),
        (.mysql, "update t set a=a+1, b=concat(b,'-') where id in (1,2,3) order by id limit 10"),
        (.sqlite, "select [x], \"y\" from t where z between 1 and 2 -- done"),
        (.postgres, "SELECT 'Hà Nội', tên FROM khách_hàng WHERE ghi_chú <> '' AND số >= -1.5e3"),
        (.postgres, "select 1; select 2;\n\n-- just a comment\nselect 3"),
    ]

    private func meaning(_ text: String, _ flavor: SQLFlavor) -> [String] {
        var words: [String] = []
        for token in SQLLexer.tokens(text, flavor: flavor) where token.kind != .whitespace {
            switch token.kind {
            // Comments keep their words; trailing spaces inside a line comment don't matter.
            case .comment:
                words.append(token.text.trimmingCharacters(in: .whitespaces))
            // Keyword and name case is layout too, for unquoted words.
            case .word:
                words.append(token.text.uppercased())
            default:
                words.append(token.text)
            }
        }
        return words
    }

    /// What a MongoDB statement runs: its target, database and every call with its arguments.
    private func commands(_ script: String) throws -> [String] {
        try MongoSplitter.statements(in: script)
            .map { statement in
                let parsed = try MongoStatement.parse(statement.text)
                var parts = ["\(parsed.target)", parsed.database ?? "-"]
                for call in parsed.calls {
                    parts.append(
                        call.name + "(" + call.arguments.map { MongoShell.format($0) }.joined(separator: ", ") + ")"
                    )
                }
                return parts.joined(separator: " ")
            }
    }

    /// MongoDB's beautify parses and rewrites: the statements must still parse to the same commands.
    func testMongoBeautifyKeepsTheCommands() throws {
        let dialect = MongoQueryDialect()
        let scripts = [
            #"db.orders.find({status:"paid",total:{$gt:5}},{_id:0}).sort({total:-1}).limit(5)"#,
            #"db.orders.aggregate([{$match:{"a.b":{$in:[1,"1",null]}}},{$group:{_id:"$s",n:{$sum:1}}}])"#,
            #"db.getSiblingDB("shop").people.insertOne({name:"Hà Nội",at:ISODate("2024-01-02T03:04:05Z"),d:NumberDecimal("0.1000"),b:BinData(0,"3q2+7w==")})"#,
            #"db.t.find({ re: /a\/b/i, n: NumberLong("9007199254740993"), x: -0.0, y: 1e300, "we ird": "q\"uote" }); db.t.countDocuments({})"#,
            #"db.t.updateMany({a:{$exists:true}},[{$set:{b:"$a"}}],{upsert:false}); show collections; use other"#,
            #"db.runCommand({ping:1}); db["odd.name"].find().skip(2).limit(3)"#,
        ]
        for script in scripts {
            let once = dialect.beautify(script)
            XCTAssertEqual(try commands(once), try commands(script), "\(script)\n→\n\(once)")
            XCTAssertEqual(dialect.beautify(once), once, "beautifying twice changes nothing:\n\(once)")
        }
    }

    func testBeautifyKeepsEveryTokenAndIsStable() {
        for (flavor, script) in scripts {
            let dialect = SQLDialect(flavor: flavor)
            let once = dialect.beautify(script)
            XCTAssertEqual(meaning(once, flavor), meaning(script, flavor), "\(flavor): \(script)\n→\n\(once)")
            XCTAssertEqual(dialect.beautify(once), once, "beautifying twice changes nothing:\n\(once)")
            XCTAssertEqual(
                dialect.split(once).count,
                dialect.split(script).count,
                "the same statements:\n\(once)"
            )
        }
    }
}
