import Foundation
import WhoopProtocol

// MARK: - StepCounter
//
// Activity-derived daily step estimate from ~1 Hz gravity. Not a true pedometer:
// at 1 Hz walking is undercounted, so minutes are classified (sedentary / walk /
// active) from RMS of gravity deltas and a capped cadence is applied.

enum StepCounter {
    static let sedentaryRMS: Double = 0.02
    static let walkRMS: Double = 0.12
    static let walkSpm: Int = 100
    static let activeSpm: Int = 130
    static let minuteS: Int = 60

    /// Estimated steps over `gravity`. Still / missing input → 0.
    static func count(_ gravity: [GravitySample]) -> Int {
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
            let minute = row.ts / minuteS
            byMinute[minute, default: []].append(delta)
        }

        var steps = 0
        for deltas in byMinute.values {
            guard !deltas.isEmpty else { continue }
            let rms = sqrt(deltas.reduce(0.0) { $0 + $1 * $1 } / Double(deltas.count))
            if rms < sedentaryRMS {
                continue
            }
            let peaks = peakCount(deltas)
            if rms < walkRMS {
                let cap = Int(Double(walkSpm) * Double(deltas.count) / Double(minuteS))
                steps += min(max(peaks, cap > 0 ? cap : walkSpm / 2), walkSpm)
            } else {
                let cap = Int(Double(activeSpm) * Double(deltas.count) / Double(minuteS))
                steps += min(max(peaks, cap > 0 ? cap : activeSpm / 2), activeSpm)
            }
        }
        return steps
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
}
