import Foundation

// MARK: - HRChartPresentation
// Pure helpers for raw-HR chart display: time bucketing and Apple-like Y scaling.
// Raw samples stay in the store / MetricsRepository; only presentation is affected.

enum HRChartPresentation {

    /// Default bin width for compact Trends card (24h window).
    static let compactBinSeconds = 120

    /// Default bin width for Heart Rate detail view (higher resolution).
    static let detailBinSeconds = 60

    /// Minimum Y span so flat segments still read clearly (bpm).
    static let minimumYSpan = 12.0

    /// Fractional padding above/below the data range.
    static let yPaddingFraction = 0.08

    // MARK: - Bucketing

    /// Averages HR samples into fixed wall-clock bins (e.g. 60s or 120s).
    /// Empty input returns []. Single-point input is returned unchanged.
    static func bucket(points: [TrendPoint], intervalSeconds: Int) -> [TrendPoint] {
        guard intervalSeconds > 0 else { return points }
        guard points.count >= 2 else { return points }

        let sorted = points.sorted { $0.date < $1.date }
        let interval = Double(intervalSeconds)

        struct Accumulator {
            var sum: Double = 0
            var count: Int = 0
            var binStart: TimeInterval = 0
        }

        var bins: [Int: Accumulator] = [:]
        bins.reserveCapacity(sorted.count / max(1, intervalSeconds))

        for pt in sorted {
            let t = pt.date.timeIntervalSince1970
            let binStart = floor(t / interval) * interval
            let key = Int(binStart)
            if bins[key] == nil {
                bins[key] = Accumulator(binStart: binStart)
            }
            bins[key]!.sum += pt.value
            bins[key]!.count += 1
        }

        return bins.keys.sorted().compactMap { key -> TrendPoint? in
            guard let acc = bins[key], acc.count > 0 else { return nil }
            let avg = acc.sum / Double(acc.count)
            let center = acc.binStart + interval / 2.0
            let id = "hr-\(key)"
            return TrendPoint(
                id: id,
                date: Date(timeIntervalSince1970: center),
                value: avg
            )
        }
    }

    // MARK: - Y domain

    /// Scales the Y axis to the min–max of `points` with modest padding and a minimum span.
    /// Does not anchor at zero — mirrors Apple Health HR charts.
    static func yDomain(
        for points: [TrendPoint],
        paddingFraction: Double = yPaddingFraction,
        minSpan: Double = minimumYSpan
    ) -> ClosedRange<Double> {
        guard !points.isEmpty else { return 50...90 }

        let vals = points.map(\.value)
        var lo = vals.min() ?? 50
        var hi = vals.max() ?? 90

        if hi - lo < minSpan {
            let mid = (lo + hi) / 2.0
            lo = mid - minSpan / 2.0
            hi = mid + minSpan / 2.0
        }

        let span = hi - lo
        let pad = max(span * paddingFraction, 2.0)
        lo -= pad
        hi += pad

        // Keep within plausible HR bounds without forcing zero.
        lo = max(30, lo)
        hi = min(220, hi)

        if hi <= lo { hi = lo + minSpan }
        return lo...hi
    }

    /// Bucket then derive Y domain — convenience for chart call-sites.
    static func prepare(
        points: [TrendPoint],
        intervalSeconds: Int
    ) -> (series: [TrendPoint], yDomain: ClosedRange<Double>) {
        let bucketed = bucket(points: points, intervalSeconds: intervalSeconds)
        let domain = yDomain(for: bucketed)
        return (bucketed, domain)
    }

    // MARK: - Gap splitting

    /// Split a sorted series wherever adjacent points are farther apart than `maxGapSeconds`.
    /// Empty / single-point input returns a single segment (possibly empty).
    static func splitOnGaps(
        points: [TrendPoint],
        maxGapSeconds: TimeInterval
    ) -> [[TrendPoint]] {
        guard !points.isEmpty else { return [] }
        guard points.count >= 2 else { return [points] }

        var segments: [[TrendPoint]] = []
        var current: [TrendPoint] = [points[0]]
        for i in 1..<points.count {
            let dt = points[i].date.timeIntervalSince(points[i - 1].date)
            if dt > maxGapSeconds {
                segments.append(current)
                current = [points[i]]
            } else {
                current.append(points[i])
            }
        }
        segments.append(current)
        return segments
    }

    /// Gap threshold: 2× the wall-clock bin width used to produce `points`.
    static func gapThreshold(binSeconds: Int) -> TimeInterval {
        TimeInterval(max(1, binSeconds) * 2)
    }

    // MARK: - Zone-colored runs

    /// One contiguous Catmull-Rom stroke: same Edwards zone, no missing-data gap.
    struct HRRun: Identifiable, Equatable {
        let id: String
        let zone: Int
        let points: [TrendPoint]
    }

    /// Split bucketed HR into gap-aware, zone-homogeneous runs so the chart never
    /// interpolates across missing data or zone boundaries.
    static func zoneRuns(
        points: [TrendPoint],
        binSeconds: Int,
        restingHR: Double,
        maxHR: Double
    ) -> [HRRun] {
        let segments = splitOnGaps(points: points, maxGapSeconds: gapThreshold(binSeconds: binSeconds))
        var runs: [HRRun] = []
        for (segIdx, seg) in segments.enumerated() {
            guard !seg.isEmpty else { continue }
            var runPoints: [TrendPoint] = []
            var runZone = Strain.edwardsZone(bpm: seg[0].value, restingHR: restingHR, maxHR: maxHR)
            for pt in seg {
                let z = Strain.edwardsZone(bpm: pt.value, restingHR: restingHR, maxHR: maxHR)
                if z != runZone, !runPoints.isEmpty {
                    runs.append(HRRun(
                        id: "g\(segIdx)-r\(runs.count)",
                        zone: runZone,
                        points: runPoints))
                    runPoints = []
                    runZone = z
                }
                runPoints.append(pt)
            }
            if !runPoints.isEmpty {
                runs.append(HRRun(
                    id: "g\(segIdx)-r\(runs.count)",
                    zone: runZone,
                    points: runPoints))
            }
        }
        return runs
    }

    static func zoneLabel(_ zone: Int) -> String {
        switch zone {
        case 0: return "Rest"
        case 1: return "Warm-up"
        case 2: return "Fat-burn"
        case 3: return "Cardio"
        case 4: return "Hard"
        case 5: return "Peak"
        default: return "Zone \(zone)"
        }
    }

    // MARK: - Y ticks

    /// 4–5 evenly spaced ticks across `domain`, snapped to 5-bpm (or 10-bpm) steps.
    static func yTickValues(
        domain: ClosedRange<Double>,
        desiredCount: Int = 5
    ) -> [Double] {
        let lo = domain.lowerBound
        let hi = domain.upperBound
        guard hi > lo else { return [lo] }

        let desired = min(5, max(4, desiredCount))
        let rawStep = (hi - lo) / Double(desired - 1)
        let step: Double
        if rawStep <= 5 {
            step = 5
        } else if rawStep <= 10 {
            step = 10
        } else {
            step = (rawStep / 5).rounded(.up) * 5
        }

        var ticks: [Double] = []
        var v = (lo / step).rounded(.up) * step
        if ticks.isEmpty || abs((ticks.last ?? lo) - lo) > 0.1 {
            ticks.append((lo * 10).rounded() / 10)
        }
        while v <= hi + 0.01 {
            let snapped = (v * 10).rounded() / 10
            if snapped >= lo - 0.01, snapped <= hi + 0.01 {
                if ticks.last.map({ abs($0 - snapped) > 0.05 }) ?? true {
                    ticks.append(snapped)
                }
            }
            v += step
        }
        let hiNice = (hi * 10).rounded() / 10
        if ticks.last.map({ abs($0 - hiNice) > 0.1 }) ?? true {
            ticks.append(hiNice)
        }

        if ticks.count > 5 {
            let first = ticks[0]
            let last = ticks[ticks.count - 1]
            var reduced: [Double] = [first]
            for i in 1...3 {
                reduced.append(first + (last - first) * Double(i) / 4.0)
            }
            reduced.append(last)
            ticks = reduced
        }
        if ticks.count < 2 {
            return [lo, hi]
        }
        return ticks
    }
}
