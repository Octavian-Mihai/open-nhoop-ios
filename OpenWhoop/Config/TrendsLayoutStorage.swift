import Foundation

// MARK: - TrendsLayoutStorage
// Persists user-configured Trends card order in UserDefaults (JSON array of MetricKind raw values).

enum TrendsLayoutStorage {
    static let orderKey = "com.openwhoop.trendsLayout.v1"
    /// Incremented on every save so TrendsView can refresh via @AppStorage.
    static let versionKey = "com.openwhoop.trendsLayout.version"

    static func loadOrder(defaults: UserDefaults = .standard) -> [MetricKind] {
        guard let data = defaults.data(forKey: orderKey),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return MetricKind.defaultTrendOrder
        }
        return mergeWithDefaults(sanitize(rawValues))
    }

    static func saveOrder(_ order: [MetricKind], defaults: UserDefaults = .standard) {
        let merged = mergeWithDefaults(dedupeKnown(order))
        guard let data = try? JSONEncoder().encode(merged.map(\.rawValue)) else { return }
        defaults.set(data, forKey: orderKey)
        let version = defaults.integer(forKey: versionKey)
        defaults.set(version + 1, forKey: versionKey)
    }

    static func resetToDefault(defaults: UserDefaults = .standard) {
        saveOrder(MetricKind.defaultTrendOrder, defaults: defaults)
    }

    // MARK: - Sanitization (testable)

    /// Drop unknown raw values and dedupe while preserving first occurrence order.
    static func sanitize(_ rawValues: [String]) -> [MetricKind] {
        var seen = Set<String>()
        var result: [MetricKind] = []
        for raw in rawValues {
            guard !seen.contains(raw), let kind = MetricKind(rawValue: raw) else { continue }
            seen.insert(raw)
            result.append(kind)
        }
        return result
    }

    /// Append any missing trend kinds to the end so upgrades don't break saved prefs.
    static func mergeWithDefaults(_ order: [MetricKind]) -> [MetricKind] {
        var result = order
        let present = Set(order)
        for kind in MetricKind.allTrendCases where !present.contains(kind) {
            result.append(kind)
        }
        return result
    }

    private static func dedupeKnown(_ order: [MetricKind]) -> [MetricKind] {
        var seen = Set<MetricKind>()
        var result: [MetricKind] = []
        for kind in order where MetricKind.allTrendCases.contains(kind) && !seen.contains(kind) {
            seen.insert(kind)
            result.append(kind)
        }
        return result
    }
}
