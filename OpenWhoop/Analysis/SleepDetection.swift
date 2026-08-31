import Foundation
import WhoopProtocol

// MARK: - SleepDetection
//
// Port of server/ingest/app/analysis/sleep.py Stage 0 (accelerometer-stillness spine),
// plus a wearable-style 4-class hypnogram (wake / light / deep / REM). Heuristic — not
// clinical scoring. deepMin/remMin/lightMin are filled from the staged night.

struct SleepStageSegment: Equatable {
    var start: Double
    var end: Double
    var stage: String   // "wake" | "light" | "deep" | "rem"
}

struct DetectedSleepSession: Equatable {
    var start: Double
    var end: Double
    var efficiency: Double
    var stages: [SleepStageSegment]
    var restingHR: Double?
    var avgHRV: Double?
}

struct DailySleepSummary: Equatable {
    var totalSleepMin: Double
    var efficiency: Double
    var deepMin: Double?
    var remMin: Double?
    var lightMin: Double?
    var disturbances: Int
    var restingHR: Double?
    var avgHRV: Double?
    var sleepStart: Double?
    var sleepEnd: Double?
}

enum SleepDetection {

    /// Per-sample gravity-vector change (g) at/below which a sample is "still".
    static let gravityStillThresholdG: Double = 0.01
    /// Rolling stillness window (minutes).
    static let stillWindowMin: Int = 15
    /// Fraction of still samples within the window required to call the centre sleep.
    static let stillFraction: Double = 0.70
    /// A data gap larger than this (minutes) always breaks a run.
    static let maxGapMin: Int = 20
    /// Runs shorter than this (minutes) are absorbed into their neighbours.
    static let mergeMin: Int = 15
    /// A sleep run must exceed this duration (minutes) to count as a session.
    static let minSleepMin: Int = 60
    /// Sample interval (seconds) assumed when it cannot be inferred.
    static let defaultIntervalS: Double = 60.0
    /// Floor on the rolling-window size in samples.
    static let minWindowSamples: Int = 3
    /// Sleep run confirmed only if mean HR ≤ this multiple of the day's median HR.
    static let hrSleepBaselineMult: Double = 1.05
    /// Skip the HR refinement if a run has fewer HR samples than this.
    static let hrRefineMinSamples: Int = 30
    /// Hypnogram epoch length (seconds).
    static let stageEpochS: Double = 60
    /// Minimum deep/REM bout (seconds) before a short run is absorbed into a neighbour.
    static let minStageBoutS: Double = 5 * 60
    /// Mean-HR jump vs session median that forces wake (arousal). Kept above typical REM
    /// elevation so a modest second-half HR rise is not scored as wake.
    static let hrJumpMult: Double = 1.22
    /// Extra jump required while the epoch is still (movement already implies wake).
    static let hrJumpStillMult: Double = 1.28

    private struct Period {
        var stage: String   // "sleep" | "active"
        var start: Double
        var end: Double
    }

    // MARK: Public

    /// Detect sleep sessions from gravity (primary) or overnight low/stable HR (fallback).
    static func detect(gravity: [GravitySample],
                       hr: [HRSample] = [],
                       rr: [RRInterval] = []) -> [DetectedSleepSession] {
        let grav = gravity.sorted { $0.ts < $1.ts }
        let hrSorted = hr.sorted { $0.ts < $1.ts }
        let rrSorted = rr.sorted { $0.ts < $1.ts }

        let times: [Double]
        let flags: [Bool]
        if grav.count >= 2 {
            times = grav.map { Double($0.ts) }
            let deltas = gravityDeltas(grav)
            flags = classifyStill(times: times, deltas: deltas)
        } else if hrSorted.count >= 2 {
            // Weaker fallback: overnight sustained low HR when gravity is absent.
            times = hrSorted.map { Double($0.ts) }
            flags = classifyLowHR(hrSorted)
        } else {
            return []
        }

        var runs = buildRuns(times: times, flags: flags)
        runs = mergePeriods(runs)
        let baseline = hrBaseline(hrSorted)
        let minSleepS = Double(minSleepMin * 60)

        var sessions: [DetectedSleepSession] = []
        for p in runs {
            guard p.stage == "sleep" else { continue }
            guard (p.end - p.start) > minSleepS else { continue }
            if grav.count >= 2, !confirmSleepWithHR(p, hr: hrSorted, baseline: baseline) {
                continue
            }
            let stages = stageHypnogram(
                times: times, flags: flags, start: p.start, end: p.end,
                hr: hrSorted, rr: rrSorted)
            let eff = efficiency(start: p.start, end: p.end, stages: stages)
            let resting = RestingHR.lowest(hr: hrSorted, start: p.start, end: p.end)
            let hrv = HRV.sessionRMSSD(rr: rrSorted, start: p.start, end: p.end)
            sessions.append(DetectedSleepSession(
                start: p.start, end: p.end, efficiency: eff,
                stages: stages, restingHR: resting, avgHRV: hrv))
        }
        sessions.sort { $0.start < $1.start }
        return sessions
    }

    /// Aggregate sessions whose END falls on `day` (YYYY-MM-DD UTC).
    static func dailySummary(sessions: [DetectedSleepSession], day: String) -> DailySleepSummary {
        let matched = sessions.filter { utcDayString(from: $0.end) == day }
        guard !matched.isEmpty else {
            return DailySleepSummary(
                totalSleepMin: 0, efficiency: 0, deepMin: nil, remMin: nil, lightMin: nil,
                disturbances: 0, restingHR: nil, avgHRV: nil, sleepStart: nil, sleepEnd: nil)
        }

        var tstS = 0.0
        var inBedS = 0.0
        var effWeighted = 0.0
        var lightS = 0.0
        var deepS = 0.0
        var remS = 0.0
        var disturbances = 0
        for s in matched {
            let m = hypnogramMetrics(s)
            let inBed = s.end - s.start
            inBedS += inBed
            effWeighted += s.efficiency * inBed
            tstS += m.tstS
            lightS += m.lightS
            deepS += m.deepS
            remS += m.remS
            disturbances += m.disturbances
        }
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0
        let restingVals = matched.compactMap(\.restingHR)
        let hrvPairs = matched.compactMap { s -> (Double, Double)? in
            guard let v = s.avgHRV else { return nil }
            return (v, s.end - s.start)
        }
        let avgHRV: Double?
        if hrvPairs.isEmpty {
            avgHRV = nil
        } else {
            let total = hrvPairs.reduce(0.0) { acc, pair in acc + pair.0 * pair.1 }
            let weight = hrvPairs.reduce(0.0) { acc, pair in acc + pair.1 }
            avgHRV = weight > 0 ? total / weight : nil
        }
        return DailySleepSummary(
            totalSleepMin: tstS / 60.0,
            efficiency: efficiency,
            deepMin: deepS / 60.0,
            remMin: remS / 60.0,
            lightMin: lightS / 60.0,
            disturbances: disturbances,
            restingHR: restingVals.min(),
            avgHRV: avgHRV,
            sleepStart: matched.map(\.start).min(),
            sleepEnd: matched.map(\.end).max())
    }

    static func utcDayString(from epoch: Double) -> String {
        AnalysisUTC.yyyyMMdd(from: Date(timeIntervalSince1970: epoch))
    }

    static func encodeStagesJSON(_ stages: [SleepStageSegment]) -> String? {
        let arr: [[String: Any]] = stages.map {
            ["start": $0.start, "end": $0.end, "stage": $0.stage]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Gravity deltas / stillness

    /// L2 magnitude of the gravity change vs the previous record. First sample is 0.
    static func gravityDeltas(_ grav: [GravitySample]) -> [Double] {
        var deltas: [Double] = []
        deltas.reserveCapacity(grav.count)
        var previous: (Double, Double, Double)?
        for (position, row) in grav.enumerated() {
            let current = (row.x, row.y, row.z)
            if position == 0 {
                deltas.append(0)
            } else if let prev = previous {
                let dx = prev.0 - current.0
                let dy = prev.1 - current.1
                let dz = prev.2 - current.2
                deltas.append(sqrt(dx * dx + dy * dy + dz * dz))
            } else {
                deltas.append(.infinity)
            }
            previous = current
        }
        return deltas
    }

    // MARK: Internals

    private static func medianInterval(_ times: [Double]) -> Double {
        guard times.count >= 2 else { return defaultIntervalS }
        var gaps: [Double] = []
        for i in 0..<(times.count - 1) {
            let gap = times[i + 1] - times[i]
            if gap > 0, gap < 300 { gaps.append(gap) }
        }
        gaps.sort()
        guard !gaps.isEmpty else { return defaultIntervalS }
        return max(gaps[gaps.count / 2], 1.0)
    }

    private static func windowSize(_ times: [Double]) -> Int {
        let interval = medianInterval(times)
        return max(minWindowSamples, Int((Double(stillWindowMin) * 60) / interval))
    }

    /// Prefix-sum equivalent of the centered rolling stillness fraction in sleep.py.
    private static func classifyStill(times: [Double], deltas: [Double]) -> [Bool] {
        let n = deltas.count
        if n < 2 { return Array(repeating: false, count: n) }
        var prefix = [0]
        prefix.reserveCapacity(n + 1)
        var running = 0
        for d in deltas {
            if d < gravityStillThresholdG { running += 1 }
            prefix.append(running)
        }
        let half = windowSize(times) / 2
        var flags = [Bool]()
        flags.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let stillCount = prefix[hi] - prefix[lo]
            let windowLen = hi - lo
            flags.append(windowLen > 0 && (Double(stillCount) / Double(windowLen)) >= stillFraction)
        }
        return flags
    }

    /// Weaker HR-only spine: rolling fraction of samples at/below median × 1.05.
    private static func classifyLowHR(_ hr: [HRSample]) -> [Bool] {
        let n = hr.count
        if n < 2 { return Array(repeating: false, count: n) }
        let bpms = hr.map { Double($0.bpm) }
        guard let baseline = median(bpms) else { return Array(repeating: false, count: n) }
        let cap = baseline * hrSleepBaselineMult
        let times = hr.map { Double($0.ts) }
        var prefix = [0]
        var running = 0
        for bpm in bpms {
            if bpm <= cap { running += 1 }
            prefix.append(running)
        }
        let half = windowSize(times) / 2
        var flags = [Bool]()
        flags.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let lowCount = prefix[hi] - prefix[lo]
            let windowLen = hi - lo
            flags.append(windowLen > 0 && (Double(lowCount) / Double(windowLen)) >= stillFraction)
        }
        return flags
    }

    private static func buildRuns(times: [Double], flags: [Bool]) -> [Period] {
        let n = times.count
        guard n > 0, flags.count == n else { return [] }
        let maxGapS = Double(maxGapMin * 60)
        var periods: [Period] = []
        var runStart = 0
        for i in 1...n {
            let close: Bool
            if i == n {
                close = true
            } else {
                let classChanged = flags[i] != flags[runStart]
                let gapExceeded = (times[i] - times[i - 1]) > maxGapS
                close = classChanged || gapExceeded
            }
            if close {
                periods.append(Period(
                    stage: flags[runStart] ? "sleep" : "active",
                    start: times[runStart],
                    end: times[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    private static func mergePeriods(_ periods: [Period]) -> [Period] {
        guard !periods.isEmpty else { return [] }
        var pending = periods
        let thresholdS = Double(mergeMin * 60)
        var merged: [Period] = []
        var i = 0
        while i < pending.count {
            let current = pending[i]
            let tooShort = (current.end - current.start) < thresholdS
            if !tooShort {
                merged.append(current)
                i += 1
                continue
            }
            let hasPrev = i > 0 && !merged.isEmpty
            let hasNext = i + 1 < pending.count
            let bridgesSameClass = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage
            if bridgesSameClass {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: pending[i + 1].end))
                i += 2
            } else if hasNext {
                pending[i + 1].start = current.start
                i += 1
            } else if hasPrev {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    private static func hrBaseline(_ hr: [HRSample]) -> Double? {
        median(hr.map { Double($0.bpm) })
    }

    private static func confirmSleepWithHR(_ period: Period, hr: [HRSample], baseline: Double?) -> Bool {
        guard let baseline else { return true }
        let seg = hr.filter { Double($0.ts) >= period.start && Double($0.ts) <= period.end }
        if seg.count < hrRefineMinSamples { return true }
        let meanHR = seg.reduce(0.0) { $0 + Double($1.bpm) } / Double(seg.count)
        return meanHR <= baseline * hrSleepBaselineMult
    }

    private static func stageHypnogram(times: [Double], flags: [Bool],
                                       start: Double, end: Double,
                                       hr: [HRSample], rr: [RRInterval]) -> [SleepStageSegment] {
        let duration = end - start
        guard duration > 0 else {
            return [SleepStageSegment(start: start, end: end, stage: "light")]
        }

        let sessionHR = hr.filter { Double($0.ts) >= start && Double($0.ts) <= end }
            .map { Double($0.bpm) }
        let sessionMedian = median(sessionHR)
        let sessionQ1: Double? = {
            guard sessionHR.count >= 4 else { return sessionMedian }
            let s = sessionHR.sorted()
            return s[s.count / 4]
        }()
        let sessionRR = rr.compactMap { row -> Double? in
            let ts = Double(row.ts)
            guard ts >= start, ts <= end else { return nil }
            return Double(row.rrMs)
        }
        let sessionRMSSD = HRV.rmssd(sessionRR)

        let epoch = stageEpochS
        var epochs: [(start: Double, end: Double, stage: String)] = []
        var t = start
        while t < end {
            let e1 = min(t + epoch, end)
            epochs.append((t, e1, classifyEpoch(
                start: t, end: e1, sessionStart: start, sessionEnd: end,
                times: times, flags: flags, hr: hr, rr: rr,
                sessionMedian: sessionMedian, sessionQ1: sessionQ1, sessionRMSSD: sessionRMSSD)))
            t = e1
        }

        // Merge consecutive identical labels, then absorb short deep/REM into neighbours.
        var segs = collapseEpochs(epochs)
        segs = absorbShortBouts(segs)
        guard !segs.isEmpty else {
            return [SleepStageSegment(start: start, end: end, stage: "light")]
        }
        segs[0].start = start
        segs[segs.count - 1].end = end
        return segs
    }

    private static func classifyEpoch(start: Double, end: Double,
                                      sessionStart: Double, sessionEnd: Double,
                                      times: [Double], flags: [Bool],
                                      hr: [HRSample], rr: [RRInterval],
                                      sessionMedian: Double?, sessionQ1: Double?,
                                      sessionRMSSD: Double?) -> String {
        let still = epochStill(start: start, end: end, times: times, flags: flags)
        let hrSeg = hr.filter { Double($0.ts) >= start && Double($0.ts) < end }
        let meanHR: Double? = hrSeg.isEmpty ? nil
            : hrSeg.reduce(0.0) { $0 + Double($1.bpm) } / Double(hrSeg.count)
        let hrStd: Double = {
            guard hrSeg.count >= 2, let mean = meanHR else { return 0 }
            let varSum = hrSeg.reduce(0.0) {
                let d = Double($1.bpm) - mean
                return $0 + d * d
            }
            return sqrt(varSum / Double(hrSeg.count - 1))
        }()
        let rrSeg = rr.compactMap { row -> Double? in
            let ts = Double(row.ts)
            guard ts >= start, ts < end else { return nil }
            return Double(row.rrMs)
        }
        let rmssd = HRV.rmssd(rrSeg)

        let jumpThresh = still ? hrJumpStillMult : hrJumpMult
        let hrJump = meanHR != nil && sessionMedian != nil
            && meanHR! > sessionMedian! * jumpThresh
        if !still || hrJump { return "wake" }

        let duration = max(sessionEnd - sessionStart, 1)
        let nightFrac = ((start + end) / 2 - sessionStart) / duration
        let lowHR = meanHR != nil && sessionQ1 != nil && meanHR! <= sessionQ1! * 1.02
        let lowVar = hrStd < 3.0 && (rmssd == nil || sessionRMSSD == nil || rmssd! <= sessionRMSSD! * 0.95)
        let highVar = hrStd >= 4.0 || (rmssd != nil && sessionRMSSD != nil && rmssd! > sessionRMSSD! * 1.08)
        let elevatedHR = meanHR != nil && sessionMedian != nil && meanHR! > sessionMedian! * 1.03

        if lowHR && lowVar && nightFrac < 0.55 { return "deep" }
        if (highVar || elevatedHR) && nightFrac > 0.40 { return "rem" }
        return "light"
    }

    private static func epochStill(start: Double, end: Double, times: [Double], flags: [Bool]) -> Bool {
        guard times.count == flags.count, !times.isEmpty else { return true }
        var still = 0
        var n = 0
        for i in 0..<times.count {
            if times[i] >= start && times[i] < end {
                n += 1
                if flags[i] { still += 1 }
            }
        }
        if n == 0 {
            // Nearest sample.
            var best = 0
            var bestDist = Double.infinity
            let mid = (start + end) / 2
            for i in 0..<times.count {
                let d = abs(times[i] - mid)
                if d < bestDist { bestDist = d; best = i }
            }
            return flags[best]
        }
        return Double(still) / Double(n) >= 0.5
    }

    private static func collapseEpochs(
        _ epochs: [(start: Double, end: Double, stage: String)]
    ) -> [SleepStageSegment] {
        var segs: [SleepStageSegment] = []
        for e in epochs {
            if let last = segs.last, last.stage == e.stage {
                segs[segs.count - 1].end = e.end
            } else {
                segs.append(SleepStageSegment(start: e.start, end: e.end, stage: e.stage))
            }
        }
        return segs
    }

    /// Deep/REM bouts shorter than `minStageBoutS` become light (or the neighbour if both sides match).
    private static func absorbShortBouts(_ segs: [SleepStageSegment]) -> [SleepStageSegment] {
        guard segs.count > 1 else { return segs }
        var out = segs
        var i = 0
        while i < out.count {
            let dur = out[i].end - out[i].start
            let isCore = out[i].stage == "deep" || out[i].stage == "rem"
            if isCore && dur < minStageBoutS {
                if i > 0 {
                    out[i - 1].end = out[i].end
                    out.remove(at: i)
                    if i < out.count, out[i].stage == out[i - 1].stage {
                        out[i - 1].end = out[i].end
                        out.remove(at: i)
                    }
                    continue
                } else if i + 1 < out.count {
                    out[i + 1].start = out[i].start
                    out.remove(at: i)
                    continue
                }
            }
            i += 1
        }
        return out
    }

    private static func efficiency(start: Double, end: Double, stages: [SleepStageSegment]) -> Double {
        let inBed = end - start
        guard inBed > 0 else { return 0 }
        let wake = stages.filter { $0.stage == "wake" }.reduce(0.0) { $0 + ($1.end - $1.start) }
        let asleep = max(0, inBed - wake)
        return min(1.0, asleep / inBed)
    }

    private struct HypnoMetrics {
        var tstS: Double
        var lightS: Double
        var deepS: Double
        var remS: Double
        var disturbances: Int
    }

    private static func hypnogramMetrics(_ session: DetectedSleepSession) -> HypnoMetrics {
        let segs = session.stages.sorted { $0.start < $1.start }
        let sleepSegs = segs.filter { ["light", "deep", "rem"].contains($0.stage) }
        let tst = sleepSegs.reduce(0.0) { $0 + ($1.end - $1.start) }
        let lightS = segs.filter { $0.stage == "light" }.reduce(0.0) { $0 + ($1.end - $1.start) }
        let deepS = segs.filter { $0.stage == "deep" }.reduce(0.0) { $0 + ($1.end - $1.start) }
        let remS = segs.filter { $0.stage == "rem" }.reduce(0.0) { $0 + ($1.end - $1.start) }
        let onset = sleepSegs.first?.start ?? session.end
        let sptEnd = sleepSegs.last?.end ?? session.end
        var disturbances = 0
        for s in segs where s.stage == "wake" {
            let w0 = max(s.start, onset)
            let w1 = min(s.end, sptEnd)
            if w1 > w0 { disturbances += 1 }
        }
        return HypnoMetrics(tstS: tst, lightS: lightS, deepS: deepS, remS: remS, disturbances: disturbances)
    }

    private static func median(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        let s = vals.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

// MARK: - UTC calendar helpers (shared by LocalMetricsEngine)

enum AnalysisUTC {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    static func yyyyMMdd(from date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func date(fromYYYYMMDD day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }
}
