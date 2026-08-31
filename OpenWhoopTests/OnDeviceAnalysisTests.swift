import XCTest
import WhoopProtocol
@testable import OpenWhoop

final class SpO2Tests: XCTestCase {

    func testRatioToSpO2KnownR() {
        // AC/DC red = 0.02, IR = 0.04 → R = 0.5 → 110 − 25*0.5 = 97.5
        // std/mean ≈ AC/DC for a sine: generate DC±AC square-ish windows.
        let red = sineWindow(dc: 10_000, ac: 200, n: 16)
        let ir  = sineWindow(dc: 20_000, ac: 800, n: 16)
        let r = SpO2.acdc(red)!
        let i = SpO2.acdc(ir)!
        XCTAssertEqual(r / i, 0.5, accuracy: 0.05)
        let pct = try! XCTUnwrap(SpO2.ratioToSpO2(red: red, ir: ir))
        XCTAssertEqual(pct, 97.5, accuracy: 2.0)
        XCTAssertGreaterThanOrEqual(pct, 80)
        XCTAssertLessThanOrEqual(pct, 100)
    }

    func testOvernightMedianSkipsEmpty() {
        XCTAssertNil(SpO2.overnightMedian(samples: [], sleepStart: 0, sleepEnd: 100))
    }

    func testOvernightMedianFromSineSeries() {
        let t0 = 1_700_000_000
        var samples: [SpO2Sample] = []
        for i in 0..<120 {
            let phase = Double(i) * 0.4
            let red = Int(10_000 + 200 * sin(phase))
            let ir  = Int(20_000 + 800 * sin(phase))
            samples.append(SpO2Sample(ts: t0 + i, red: red, ir: ir))
        }
        let pct = SpO2.overnightMedian(samples: samples,
                                       sleepStart: Double(t0),
                                       sleepEnd: Double(t0 + 120))
        XCTAssertNotNil(pct)
        XCTAssertGreaterThan(pct ?? 0, 90)
        XCTAssertLessThanOrEqual(pct ?? 0, 100)
    }

    private func sineWindow(dc: Double, ac: Double, n: Int) -> [Double] {
        (0..<n).map { dc + ac * sin(Double($0) * .pi / 4) }
    }
}

final class SkinTempTests: XCTestCase {

    func testCelsiusFromRawTenths() {
        XCTAssertEqual(SkinTemp.celsius(raw: 333), 33.3, accuracy: 0.001)
    }

    func testDeviationFromBaseline() {
        // Tonight 343 (34.3 °C), baseline nights 333 (33.3 °C) → +1.0 °C
        let dev = SkinTemp.deviationC(tonightRaw: 343, baselineRaw: [330, 333, 336])
        XCTAssertEqual(dev ?? 0, 1.0, accuracy: 0.15)
    }

    func testDeviationZeroWithoutBaseline() {
        let dev = SkinTemp.deviationC(tonightRaw: 333, baselineRaw: [])
        XCTAssertEqual(dev ?? -1, 0, accuracy: 0.001)
    }

    func testOvernightMedianRaw() {
        let t0 = 1_700_000_000
        let rows = [
            SkinTempSample(ts: t0, raw: 330),
            SkinTempSample(ts: t0 + 10, raw: 333),
            SkinTempSample(ts: t0 + 20, raw: 336),
        ]
        let med = SkinTemp.overnightMedianRaw(samples: rows, start: Double(t0), end: Double(t0 + 30))
        XCTAssertEqual(med ?? 0, 333, accuracy: 0.001)
    }

    func testPriorOvernightMediansExcludesToday() {
        let t0 = 1_700_000_000.0
        let today = SleepDetection.utcDayString(from: t0)
        let rows = [
            SkinTempSample(ts: Int(t0), raw: 400),
            SkinTempSample(ts: Int(t0 - 86_400), raw: 333),
            SkinTempSample(ts: Int(t0 - 86_400 + 10), raw: 335),
        ]
        let prior = SkinTemp.priorOvernightMedians(samples: rows, excludeDay: today)
        XCTAssertEqual(prior.count, 1)
        XCTAssertEqual(prior[0], 334, accuracy: 0.001)
    }
}

final class ExerciseDetectionTests: XCTestCase {

    private let t0 = 1_700_000_000
    private let rest = 60.0
    private let maxHR = 180.0   // 50% HRR = 120 bpm

    private func hr(start: Int, minutes: Int, bpm: Int) -> [HRSample] {
        (0..<(minutes * 60)).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testElevatedWindowYieldsOneBout() {
        let samples = hr(start: t0, minutes: 15, bpm: 140)
        let bouts = ExerciseDetection.detect(
            hr: samples, sleep: [], restingHR: rest, maxHR: maxHR, deviceId: "dev")
        XCTAssertEqual(bouts.count, 1)
        XCTAssertEqual(bouts[0].peakHr, 140)
        XCTAssertGreaterThanOrEqual(bouts[0].durationS, 10 * 60)
        XCTAssertEqual(bouts[0].kind, "Activity")
    }

    func testSleepOverlappedHRIgnored() {
        let samples = hr(start: t0, minutes: 15, bpm: 140)
        let sleep = [(start: Double(t0), end: Double(t0 + 15 * 60))]
        let bouts = ExerciseDetection.detect(
            hr: samples, sleep: sleep, restingHR: rest, maxHR: maxHR, deviceId: "dev")
        XCTAssertTrue(bouts.isEmpty, "HR entirely inside sleep must not make a bout")
    }

    func testShortSpikeIgnored() {
        let samples = hr(start: t0, minutes: 3, bpm: 160)
        let bouts = ExerciseDetection.detect(
            hr: samples, sleep: [], restingHR: rest, maxHR: maxHR, deviceId: "dev")
        XCTAssertTrue(bouts.isEmpty, "spikes shorter than 10 minutes must be dropped")
    }

    func testLocalWorkoutStoreRoundTrip() {
        LocalWorkoutStore.resetForTests()
        let samples = hr(start: t0, minutes: 15, bpm: 150)
        let bouts = ExerciseDetection.detect(
            hr: samples, sleep: [], restingHR: rest, maxHR: maxHR, deviceId: "dev")
        XCTAssertEqual(bouts.count, 1)
        let day = SleepDetection.utcDayString(from: Double(bouts[0].startTs))
        LocalWorkoutStore.replace(deviceId: "dev", day: day, workouts: bouts)
        let loaded = LocalWorkoutStore.workouts(deviceId: "dev", from: day, to: day)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, bouts[0].id)
        LocalWorkoutStore.resetForTests()
    }
}

final class StepCounterTests: XCTestCase {

    func testStillGravityYieldsZeroSteps() {
        let rows = (0..<120).map { GravitySample(ts: 1_700_000_000 + $0, x: 0, y: 0, z: 1) }
        XCTAssertEqual(StepCounter.count(rows), 0)
    }

    func testOscillatingWalkLikeGravityYieldsNonZero() {
        var rows: [GravitySample] = []
        for i in 0..<(20 * 60) {
            // ~1.5 Hz-ish walk at 1 Hz sampling: alternate z around 1 g.
            let z = i % 2 == 0 ? 1.25 : 0.75
            rows.append(GravitySample(ts: 1_700_000_000 + i, x: 0.2 * sin(Double(i)), y: 0, z: z))
        }
        let steps = StepCounter.count(rows)
        XCTAssertGreaterThan(steps, 0, "walk-like oscillation must produce a non-zero estimate")
    }
}
