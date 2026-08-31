import XCTest
@testable import OpenWhoop

final class HRChartPresentationTests: XCTestCase {

    // MARK: - Helpers

    private func point(epoch: TimeInterval, bpm: Double) -> TrendPoint {
        TrendPoint(id: "\(Int(epoch))", date: Date(timeIntervalSince1970: epoch), value: bpm)
    }

    // MARK: - Bucketing

    func testBucketEmptyReturnsEmpty() {
        XCTAssertTrue(HRChartPresentation.bucket(points: [], intervalSeconds: 60).isEmpty)
    }

    func testBucketSinglePointReturnsUnchanged() {
        let pts = [point(epoch: 1_700_000_000, bpm: 72)]
        XCTAssertEqual(HRChartPresentation.bucket(points: pts, intervalSeconds: 60), pts)
    }

    func testBucketAveragesIntoWallClockBins() {
        // Two 60s bins: 0–59s and 60–119s from a round epoch.
        let base = 1_700_000_000.0
        let pts = [
            point(epoch: base + 10, bpm: 60),
            point(epoch: base + 20, bpm: 80),
            point(epoch: base + 70, bpm: 100),
            point(epoch: base + 80, bpm: 120),
        ]
        let bucketed = HRChartPresentation.bucket(points: pts, intervalSeconds: 60)
        XCTAssertEqual(bucketed.count, 2)
        XCTAssertEqual(bucketed[0].value, 70, accuracy: 0.001)
        XCTAssertEqual(bucketed[1].value, 110, accuracy: 0.001)
    }

    func testBucketCentersDateInBin() {
        let interval = 60
        let binStart = 1_700_000_040.0
        let pts = [
            point(epoch: binStart + 5, bpm: 70),
            point(epoch: binStart + 15, bpm: 74),
        ]
        let bucketed = HRChartPresentation.bucket(points: pts, intervalSeconds: interval)
        XCTAssertEqual(bucketed.count, 1)
        XCTAssertEqual(bucketed[0].date.timeIntervalSince1970, binStart + 30, accuracy: 0.001)
    }

    func testBucketTwoMinuteBinsReducePointCount() {
        let interval = 120
        let binStart = floor(1_700_000_000.0 / Double(interval)) * Double(interval)
        var pts: [TrendPoint] = []
        for i in 0..<100 {
            pts.append(point(epoch: binStart + Double(i), bpm: 60 + Double(i % 10)))
        }
        let bucketed = HRChartPresentation.bucket(points: pts, intervalSeconds: interval)
        XCTAssertEqual(bucketed.count, 1)
    }

    func testBucketPreservesChronologicalOrder() {
        let base = 1_700_000_000.0
        let pts = [
            point(epoch: base + 130, bpm: 90),
            point(epoch: base + 10, bpm: 70),
            point(epoch: base + 70, bpm: 80),
        ]
        let bucketed = HRChartPresentation.bucket(points: pts, intervalSeconds: 60)
        XCTAssertEqual(bucketed.map(\.value), [70, 80, 90])
        for i in 1..<bucketed.count {
            XCTAssertLessThan(bucketed[i - 1].date, bucketed[i].date)
        }
    }

    // MARK: - Y domain

    func testYDomainUsesDataRangeNotZeroAnchored() {
        let pts = (0..<5).map { point(epoch: 1_700_000_000 + Double($0 * 60), bpm: 68 + Double($0)) }
        let domain = HRChartPresentation.yDomain(for: pts)
        XCTAssertGreaterThan(domain.lowerBound, 30)
        XCTAssertLessThan(domain.upperBound, 100)
        XCTAssertGreaterThan(domain.upperBound - domain.lowerBound, 5)
    }

    func testYDomainEnforcesMinimumSpan() {
        let pts = [
            point(epoch: 1_700_000_000, bpm: 72),
            point(epoch: 1_700_000_060, bpm: 73),
        ]
        let domain = HRChartPresentation.yDomain(for: pts, minSpan: 12)
        XCTAssertGreaterThanOrEqual(domain.upperBound - domain.lowerBound, 12)
    }

    func testYDomainEmptyFallback() {
        let domain = HRChartPresentation.yDomain(for: [])
        XCTAssertEqual(domain.lowerBound, 50)
        XCTAssertEqual(domain.upperBound, 90)
    }

    func testPrepareBucketsAndComputesDomain() {
        let base = 1_700_000_000.0
        let pts = [
            point(epoch: base + 10, bpm: 60),
            point(epoch: base + 20, bpm: 80),
            point(epoch: base + 70, bpm: 100),
        ]
        let prepared = HRChartPresentation.prepare(points: pts, intervalSeconds: 60)
        XCTAssertEqual(prepared.series.count, 2)
        XCTAssertGreaterThan(prepared.yDomain.upperBound, prepared.yDomain.lowerBound)
        XCTAssertGreaterThan(prepared.yDomain.lowerBound, 0)
    }

    // MARK: - Gap splitting

    func testSplitOnGapsEmpty() {
        XCTAssertTrue(HRChartPresentation.splitOnGaps(points: [], maxGapSeconds: 120).isEmpty)
    }

    func testSplitOnGapsSingleSegmentWhenContinuous() {
        let base = 1_700_000_000.0
        let pts = (0..<5).map { point(epoch: base + Double($0 * 60), bpm: 70) }
        let segs = HRChartPresentation.splitOnGaps(points: pts, maxGapSeconds: 120)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].count, 5)
    }

    func testSplitOnGapsBreaksWhenAdjacentExceedsTwiceBinWidth() {
        let bin = 60
        let base = 1_700_000_000.0
        let pts = [
            point(epoch: base, bpm: 70),
            point(epoch: base + 60, bpm: 72),
            // 5-minute hole > 2×60s
            point(epoch: base + 360, bpm: 80),
            point(epoch: base + 420, bpm: 82),
        ]
        let segs = HRChartPresentation.splitOnGaps(
            points: pts,
            maxGapSeconds: HRChartPresentation.gapThreshold(binSeconds: bin))
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].map(\.value), [70, 72])
        XCTAssertEqual(segs[1].map(\.value), [80, 82])
    }

    func testGapThresholdIsTwiceBinWidth() {
        XCTAssertEqual(HRChartPresentation.gapThreshold(binSeconds: 60), 120)
        XCTAssertEqual(HRChartPresentation.gapThreshold(binSeconds: 120), 240)
    }

    // MARK: - Zone assignment

    func testZoneRunsAssignEdwardsBands() {
        // rest 60, max 180 → reserve 120. 50% = 120, 60% = 132, 70% = 144, 80% = 156, 90% = 168
        let base = 1_700_000_000.0
        let pts = [
            point(epoch: base, bpm: 70),          // rest (zone 0)
            point(epoch: base + 60, bpm: 125),    // warm-up (zone 1, ≥50%)
            point(epoch: base + 120, bpm: 140),   // fat-burn (zone 2, ≥60%)
            point(epoch: base + 180, bpm: 150),   // cardio (zone 3, ≥70%)
            point(epoch: base + 240, bpm: 165),   // hard (zone 4, ≥80%)
            point(epoch: base + 300, bpm: 175),   // peak (zone 5, ≥90%)
        ]
        let runs = HRChartPresentation.zoneRuns(
            points: pts, binSeconds: 60, restingHR: 60, maxHR: 180)
        XCTAssertEqual(runs.map(\.zone), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(runs.flatMap { $0.points }.count, 6)
    }

    func testZoneRunsDoNotBridgeGaps() {
        let base = 1_700_000_000.0
        let pts = [
            point(epoch: base, bpm: 70),
            point(epoch: base + 60, bpm: 72),
            point(epoch: base + 600, bpm: 74),   // big gap, same zone
        ]
        let runs = HRChartPresentation.zoneRuns(
            points: pts, binSeconds: 60, restingHR: 60, maxHR: 180)
        XCTAssertEqual(runs.count, 2, "same-zone points across a gap must be separate runs")
        XCTAssertEqual(runs[0].points.count, 2)
        XCTAssertEqual(runs[1].points.count, 1)
    }

    func testYTickValuesCountIsFourOrFive() {
        let ticks = HRChartPresentation.yTickValues(domain: 55...105, desiredCount: 5)
        XCTAssertGreaterThanOrEqual(ticks.count, 2)
        XCTAssertLessThanOrEqual(ticks.count, 5)
        XCTAssertEqual(ticks, ticks.sorted())
    }
}
