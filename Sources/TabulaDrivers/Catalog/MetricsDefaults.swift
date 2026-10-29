import Foundation
import TabulaFoundation
import TabulaSQL

extension Defaults {
    public enum Metrics {
        /// Largest tables listed in the metrics view.
        public static let tableLimit = 25
        public static let refreshInterval: Double = 3
        public static let refreshChoices: [Double] = [1, 3, 5, 10, 30]
        /// How much history the charts keep.
        public static let historySeconds: Double = 600
    }
}
