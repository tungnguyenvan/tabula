import MySQLNIO
import NIOCore

/// One statement over the text protocol, keeping the result's columns even when it has no rows. MySQLNIO's
/// `simpleQuery` hands the column definitions over only with each row, so an empty result had no columns.
final class MySQLTextQuery: MySQLCommand, @unchecked Sendable {
    private enum State {
        case ready
        case columns(count: Int)
        case rows
        case done
    }

    private let sql: String
    private var state = State.ready
    /// Read by the driver once the command finished; the connection's event loop writes them before that.
    private(set) var columns: [MySQLProtocol.ColumnDefinition41] = []
    private(set) var rows: [MySQLRow] = []

    init(sql: String) {
        self.sql = sql
    }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        MySQLCommandState(response: [try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            state = .done
            throw MySQLError.server(try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities))
        }
        switch state {
        case .ready:
            if packet.isOK {
                state = .done
                return MySQLCommandState(done: true)
            }
            let response = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
            state = response.columnCount == 0 ? .rows : .columns(count: Int(response.columnCount))
            return MySQLCommandState()
        case .columns(let count):
            columns.append(try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
            if columns.count == count {
                state = .rows
            }
            return MySQLCommandState()
        case .rows:
            if packet.isEOF {
                state = .done
                return MySQLCommandState(done: true)
            }
            let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count)
            rows.append(MySQLRow(format: .text, columnDefinitions: columns, values: row.values))
            return MySQLCommandState()
        case .done:
            throw MySQLError.protocolError
        }
    }
}
