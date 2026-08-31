import Foundation
import WhoopProtocol

// MARK: - StepCounter
//
// Activity-derived daily step estimate from ~1 Hz gravity. Not a true pedometer.
// Minutes are classified from RMS of gravity deltas; cadence is a CAP, never a
// floor — applying 100 spm to every non-still minute is what produced 100k+ days.

enum StepCounter {
    /// Below this RMS the minute is still / sedentary → 0 steps.
    /// 0.02 was far too low: 1 Hz noise and sleep micro-motion looked like walking.
    static let sedentaryRMS: Double = 0.08
    static let walkRMS: Double = 0.20
    static let walkSpm: Int = 100
    static let activeSpm: Int = 130
    static let maxStepsPerMinute: Int = 150
    static let dailyCap: Int = 40_000
    static let minuteS: Int = 60
    /// Regular oscillation at 1 Hz before a minute is treated as walking.
    static let minPeaksPerFullMinute: Int = 8

    /// Estimated steps over `gravity`. Still / missing input → 0.
    /// Samples that fall inside `sleepWindows` are ignored.
    static func count(
        _ gravity: [GravitySample],
        sleepWindows: [(start: Double, end: Double)] = []
    ) -> Int {
        let sorted = gravity.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return 0 }

        var byMinute: [Int: [Double]] = [:]
        var prev: (Double, Double, Double)?
        for row in sorted {
            let cur = (row.x, row.y, row.z)
            let delta: Double
            if let p = prev {
                let dx = p.0 - cur.0, dy = p.1 - cur.1, dz = p.2 - cur.2
                delta = sqrt(dx * dx + dy * dy + dz * dz)
            } else {
                delta = 0
            }
            prev = cur
            if minuteOverlapsSleep(row.ts / minuteS, windows: sleepWindows) {
                continue
            }
            let minute = row.ts / minuteS
            byMinute[minute, default: []].append(delta)
        }

        var steps = 0
        for deltas in byMinute.values {
            guard deltas.count >= 3 else { continue }
            let rms = sqrt(deltas.reduce(0.0) { $0 + $1 * $1 } / Double(deltas.count))
            if rms < sedentaryRMS { continue }

            let peaks = peakCount(deltas)
            let minPeaks = max(3, minPeaksPerFullMinute * deltas.count / minuteS)
            // Fidget / noise: some motion but not a walking cadence.
            if peaks < minPeaks { continue }

            let cadence = rms < walkRMS ? walkSpm : activeSpm
            let coverageCap = max(1, cadence * deltas.count / minuteS)
            // 1 Hz undersamples ~1.5–2 Hz walking. Scale only when the minute
            // clearly looks like walking; cadence is a cap, never a floor.
            let looksLikeWalk = peaks >= 15 && deltas.count >= 40
            let estimate = looksLikeWalk ? peaks * 2 : peaks
            steps += min(estimate, coverageCap, maxStepsPerMinute)
        }
        return min(steps, dailyCap)
    }

    /// Local maxima in the per-sample delta series (cadence-style peaks).
    static func peakCount(_ deltas: [Double]) -> Int {
        guard deltas.count >= 3 else { return 0 }
        var n = 0
        for i in 1..<(deltas.count - 1) {
            if deltas[i] > deltas[i - 1], deltas[i] >= deltas[i + 1], deltas[i] > sedentaryRMS {
                n += 1
            }
        }
        return n
    }

    static func minuteOverlapsSleep(
        _ minute: Int,
        windows: [(start: Double, end: Double)]
    ) -> Bool {
        guard !windows.isEmpty else { return false }
        let lo = Double(minute * minuteS)
        let hi = lo + Double(minuteS)
        return windows.contains { $0.start < hi && $0.end > lo }
    }
}
