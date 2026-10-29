import Foundation
import TabulaDrivers
import TabulaFoundation

extension Defaults {
    public enum Redis {
        /// COUNT hint for SCAN / HSCAN / SSCAN / ZSCAN.
        public static let scanBatch = 500
        /// Bytes of a value shown in the keys table.
        public static let previewLength = 200
        /// Elements loaded per page of a collection.
        public static let pageSize = 200
        /// The server default for `databases`, used when CONFIG GET is not allowed.
        public static let databaseCount = 16
    }
}
