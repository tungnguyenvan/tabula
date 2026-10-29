import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

extension Defaults {
    public enum Mongo {
        /// Documents read to learn a collection's fields (and their types) for the grid and completion.
        public static let sampleSize = 100
        /// Documents per round trip when a cursor needs more than one batch.
        public static let batchSize = 500
        /// Most documents one query returns into the results grid, whatever its own limit.
        public static let maxDocuments = 50_000
        /// Spaces per level when a document is written out over several lines.
        public static let indentWidth = 2
        /// Nested values up to this many characters stay on one line in pretty output.
        public static let inlineWidth = 60
        /// Database opened when the connection names none.
        public static let defaultDatabase = "test"
        /// Collections whose sizes the metrics compare to find the largest (one round trip each).
        public static let statsCollectionLimit = 500
        /// Seconds the per-collection sizes are reused between metrics samples.
        public static let statsRefreshInterval: Double = 60
        /// A seed list name has at least this many labels (cluster0.example.net), per the SRV specification.
        public static let srvMinimumLabels = 3
        /// Database that authenticates the user when the connection names none (the drivers' default).
        public static let authDatabase = "admin"
    }
}
