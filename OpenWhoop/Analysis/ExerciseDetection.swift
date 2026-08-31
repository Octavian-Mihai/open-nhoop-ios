import Foundation
import WhoopProtocol

// MARK: - ExerciseDetection
//
// On-device bout detection from 1 Hz HR. A bout is HR at ≥50% heart-rate reserve
// (Edwards zone 2+) for ≥10 minutes, ending after ≥5 minutes below that threshold.
// Gaps <3 minutes are merged; bouts <10 minutes are dropped. Sleep windows are excluded.

enum ExerciseDetection {
    static let minBoutS: Double = 10 * 60
    static let endBelowS: Double = 5 * 60
    static let mergeGapS: Double = 3 * 60
    /// Edwards zone 2+ = ≥50% HRR (zone weight ≥ 1).
    static let minZone = 1

    static func detect(hr: [HRSample],
                       sleep: [(start: Double, end: Double)],
                       restingHR: Double,
                       maxHR: Double,
                       deviceId: String) -> [Workout] {
        guard maxHR > restingHR else { return [] }
        let sorted = hr.sorted { $0.ts < $1.ts }.filter { sample in
            let t = Double(sample.ts)
            return !sleep.contains { t >= $0.start && t <= $0.end }
        }
        guard sorted.count >= 2 else { return [] }

        var elevated: [(start: Double, end: Double, samples: [HRSample])] = []
        var run: [HRSample] = []
        var belowSince: Double?

        func closeRun() {
            guard let first = run.first, let last = run.last else { return }
            // Inclusive last-sample coverage so 10 min of 1 Hz (ts span 599 s) still counts.
            let dur = Double(last.ts - first.ts) + 1
            if dur >= minBoutS {
                elevated.append((Double(first.ts), Double(last.ts) + 1, run))
            }
            run = []
            belowSince = nil
        }

        for sample in sorted {
            let zone = Strain.edwardsZone(bpm: Double(sample.bpm), restingHR: restingHR, maxHR: maxHR)
            let t = Double(sample.ts)
            if zone >= minZone {
                if !run.isEmpty, let since = belowSince, t - since >= endBelowS {
                    closeRun()
                } else if belowSince == nil, let last = run.last, t - Double(last.ts) > mergeGapS {
                    closeRun()
                }
                run.append(sample)
                belowSince = nil
            } else if !run.isEmpty {
                if belowSince == nil { belowSince = t }
                if let since = belowSince, t - since >= endBelowS {
                    closeRun()
                }
            }
        }
        closeRun()

        // Merge remaining gaps < 3 minutes.
        var merged: [(start: Double, end: Double, samples: [HRSample])] = []
        for bout in elevated {
            if let last = merged.last, bout.start - last.end < mergeGapS {
                let combined = last.samples + bout.samples
                merged[merged.count - 1] = (last.start, bout.end, combined)
            } else {
                merged.append(bout)
            }
        }

        return merged.compactMap { bout -> Workout? in
            let dur = bout.end - bout.start
            guard dur >= minBoutS, !bout.samples.isEmpty else { return nil }
            return makeWorkout(samples: bout.samples,
                               start: bout.start, end: bout.end,
                               restingHR: restingHR, maxHR: maxHR,
                               deviceId: deviceId)
        }
    }

    private static func makeWorkout(samples: [HRSample],
                                    start: Double, end: Double,
                                    restingHR: Double, maxHR: Double,
                                    deviceId: String) -> Workout {
        let bpms = samples.map { Double($0.bpm) }
        let avg = bpms.reduce(0, +) / Double(bpms.count)
        let peak = samples.map(\.bpm).max() ?? Int(avg.rounded())
        var zoneCounts = [Int: Int](uniqueKeysWithValues: (0...5).map { ($0, 0) })
        for bpm in bpms {
            let z = Strain.edwardsZone(bpm: bpm, restingHR: restingHR, maxHR: maxHR)
            zoneCounts[z, default: 0] += 1
        }
        let total = Double(bpms.count)
        var zonePct: [Int: Double] = [:]
        for z in 0...5 {
            zonePct[z] = total > 0 ? Double(zoneCounts[z] ?? 0) / total * 100.0 : 0
        }
        let avgHrr = maxHR > restingHR ? (avg - restingHR) / (maxHR - restingHR) * 100.0 : nil
        let kind = (avgHrr ?? 0) >= 70 ? "Cardio" : "Activity"
        let strainVal = Strain.strain(hr: samples, maxHR: maxHR, restingHR: restingHR)
        let startTs = Int(start.rounded())
        return Workout(
            id: "\(deviceId)|\(startTs)",
            deviceId: deviceId,
            startTs: startTs,
            endTs: Int(end.rounded()),
            avgHr: avg,
            peakHr: peak,
            strain: strainVal,
            kind: kind,
            durationS: Int((end - start).rounded()),
            zoneTimePct: zonePct,
            avgHrrPct: avgHrr,
            hrmax: maxHR,
            hrmaxSource: "local",
            caloriesKcal: nil,
            caloriesKj: nil)
    }
}
