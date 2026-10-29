import Foundation
import TabulaFoundation

extension Defaults {
    public enum Updates {
        public static let requestTimeout: Double = 20
        public static let checkInterval: TimeInterval = 24 * 60 * 60
        /// Download progress is reported in steps of this fraction.
        public static let progressStep = 0.01
    }
}
