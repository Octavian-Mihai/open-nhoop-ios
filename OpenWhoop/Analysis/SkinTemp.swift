import Foundation
import WhoopProtocol

// MARK: - SkinTemp
//
// Raw ADC (`SkinTempSample.raw`) is treated as tenths of a degree C (333 → 33.3 °C),
// matching observed fixture magnitudes. The Sleep card shows deviation from a 14-day
// overnight baseline, not absolute temperature.

enum SkinTemp {
    /// ADC counts per °C (raw 333 ≈ 33.3 °C).
    static let adcPerDegree: Double = 10.0

    static func celsius(raw: Double) -> Double {
        raw / adcPerDegree
    }

    static func overnightMedianRaw(samples: [SkinTempSample],
                                   start: Double,
                                   end: Double) -> Double? {
        let vals = samples.compactMap { row -> Double? in
            let ts = Double(row.ts)
            guard ts >= start, ts <= end else { return nil }
            return Double(row.raw)
        }
        return median(vals)
    }

    /// Tonight's overnight median minus the median of `baselineRaw` (prior nights).
    /// Returns 0 when no baseline exists yet; nil when tonight has no samples.
    static func deviationC(tonightRaw: Double?, baselineRaw: [Double]) -> Double? {
        guard let tonightRaw else { return nil }
        let tonightC = celsius(raw: tonightRaw)
        guard let base = median(baselineRaw) else { return 0 }
        return tonightC - celsius(raw: base)
    }

    /// Prior-night overnight medians: one median per UTC day in `samples`, excluding `excludeDay`.
    static func priorOvernightMedians(samples: [SkinTempSample],
                                      excludeDay: String,
                                      maxDays: Int = 14) -> [Double] {
        var byDay: [String: [Double]] = [:]
        for row in samples {
            let day = SleepDetection.utcDayString(from: Double(row.ts))
            if day == excludeDay { continue }
            byDay[day, default: []].append(Double(row.raw))
        }
        let days = byDay.keys.sorted().suffix(maxDays)
        return days.compactMap { day in median(byDay[day] ?? []) }
    }

    private static func median(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        let s = vals.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
