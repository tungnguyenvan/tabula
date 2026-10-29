import Foundation

/// One page of a table, as the grid asks for it.
public struct TablePageRequest: Sendable, Hashable {
    public var table: TableRef
    public var limit: Int
    public var offset: Int
    public var orderBy: String?
    public var ascending: Bool
    /// Raw SQL condition placed after WHERE, typed by the user.
    public var filter: String?

    public init(
        table: TableRef,
        limit: Int = Defaults.pageSize,
        offset: Int = 0,
        orderBy: String? = nil,
        ascending: Bool = true,
        filter: String? = nil
    ) {
        self.table = table
        self.limit = limit
        self.offset = offset
        self.orderBy = orderBy
        self.ascending = ascending
        self.filter = filter
    }
}
