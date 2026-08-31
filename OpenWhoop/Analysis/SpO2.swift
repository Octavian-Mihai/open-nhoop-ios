import Foundation
import WhoopProtocol

// MARK: - SpO2
//
// Wearable-style pulse-ox approximation from raw red/IR ADC during sleep.
// R = (AC/DC red) / (AC/DC IR); SpO2 ≈ 110 − 25R, clamped 80–100.
// Not clinically calibrated.

enum SpO2 {
    /// Window used to estimate AC/DC (seconds).
    static let windowS: Double = 15
    /// Gravity-vector change above this (g) is treated as motion and skipped.
    static let motionThresholdG: Double = 0.03
    static let minWindows = 3
    static let clamp: ClosedRange<Double> = 80...100

    /// Overnight median SpO2 % during [sleepStart, sleepEnd], or nil if too sparse.
    static func overnightMedian(samples: [SpO2Sample],
                                gravity: [GravitySample] = [],
                                sleepStart: Double,
                                sleepEnd: Double) -> Double? {
        let rows = samples.filter { Double($0.ts) >= sleepStart && Double($0.ts) <= sleepEnd }
            .sorted { $0.ts < $1.ts }
        guard rows.count >= 4 else { return nil }

        let motionTimes: Set<Int> = {
            guard gravity.count >= 2 else { return [] }
            let nightGrav = gravity.filter { Double($0.ts) >= sleepStart && Double($0.ts) <= sleepEnd }
                .sorted { $0.ts < $1.ts }
            let deltas = SleepDetection.gravityDeltas(nightGrav)
            var times = Set<Int>()
            for (i, d) in deltas.enumerated() where d > motionThresholdG {
                times.insert(nightGrav[i].ts)
            }
            return times
        }()

        var estimates: [Double] = []
        var i = 0
        while i < rows.count {
            let t0 = Double(rows[i].ts)
            if t0 > sleepEnd { break }
            let t1 = t0 + windowS
            var red: [Double] = []
            var ir: [Double] = []
            var j = i
            var moving = false
            while j < rows.count, Double(rows[j].ts) < t1 {
                if motionTimes.contains(rows[j].ts) { moving = true }
                red.append(Double(rows[j].red))
                ir.append(Double(rows[j].ir))
                j += 1
            }
            if !moving, let pct = ratioToSpO2(red: red, ir: ir) {
                estimates.append(pct)
            }
            i = max(j, i + 1)
        }
        guard estimates.count >= minWindows else { return nil }
        return median(estimates)
    }

    /// Map a red/IR window to SpO2 %. Nil when AC/DC cannot be computed.
    static func ratioToSpO2(red: [Double], ir: [Double]) -> Double? {
        guard let r = acdc(red), let i = acdc(ir), i > 1e-9 else { return nil }
        let ratio = r / i
        let pct = 110.0 - 25.0 * ratio
        return min(clamp.upperBound, max(clamp.lowerBound, pct))
    }

    /// AC/DC ≈ stddev / mean for a window with a usable DC level.
    static func acdc(_ values: [Double]) -> Double? {
        guard values.count >= 4 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 1 else { return nil }
        let varSum = values.reduce(0.0) { acc, v in
            let d = v - mean
            return acc + d * d
        }
        let std = sqrt(varSum / Double(values.count))
        guard std > 0 else { return nil }
        return std / mean
    }

    private static func median(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        let s = vals.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
