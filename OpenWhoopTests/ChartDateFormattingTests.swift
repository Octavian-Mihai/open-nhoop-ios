import XCTest
@testable import OpenWhoop

/// Unit tests for kind-aware chart date/time formatting.
final class ChartDateFormattingTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar.current
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.calendar = calendar
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }

    func testRawHR_axisLabel_shortSpan_showsHour() {
        let point = date(year: 2026, month: 8, day: 25, hour: 15, minute: 42)
        let label = ChartDateFormatting.axisLabel(
            date: point,
            spanSeconds: 24 * 3_600,
            kind: .rawHR
        )
        XCTAssertTrue(label.contains("PM") || label.contains("AM"), "Expected hour meridiem in axis label, got: \(label)")
        XCTAssertFalse(label.contains("/"), "Short-span HR axis should not use M/d, got: \(label)")
    }

    func testRawHR_selectionSubtitle_includesTime() {
        let point = date(year: 2026, month: 8, day: 25, hour: 15, minute: 42)
        let subtitle = ChartDateFormatting.selectionSubtitle(date: point, kind: .rawHR)
        XCTAssertTrue(subtitle.contains(":"), "Expected h:mm in subtitle, got: \(subtitle)")
        XCTAssertTrue(subtitle.contains("PM") || subtitle.contains("AM"), "Expected meridiem in subtitle, got: \(subtitle)")
        XCTAssertTrue(subtitle.contains("Aug 25"), "Expected date in subtitle, got: \(subtitle)")
    }

    func testRecovery_selectionSubtitle_dateOnly() {
        let point = date(year: 2026, month: 8, day: 25, hour: 0, minute: 0)
        let subtitle = ChartDateFormatting.selectionSubtitle(date: point, kind: .recovery)
        XCTAssertEqual(subtitle, "Aug 25")
        XCTAssertFalse(subtitle.contains(":"), "Daily metrics should stay date-only, got: \(subtitle)")
    }

    func testRawHR_axisLabel_weekSpan_showsWeekdayAndHour() {
        let point = date(year: 2026, month: 8, day: 25, hour: 9, minute: 0)
        let label = ChartDateFormatting.axisLabel(
            date: point,
            spanSeconds: 5 * 86_400,
            kind: .rawHR
        )
        XCTAssertTrue(label.contains("Mon") || label.contains("Tue") || label.contains("Wed")
            || label.contains("Thu") || label.contains("Fri") || label.contains("Sat") || label.contains("Sun"),
                      "Expected weekday in multi-day HR axis, got: \(label)")
    }

    func testRawHR_selectionSubtitle_midnightDateOnly() {
        let point = date(year: 2026, month: 8, day: 25, hour: 0, minute: 0)
        let subtitle = ChartDateFormatting.selectionSubtitle(date: point, kind: .rawHR)
        XCTAssertEqual(subtitle, "Aug 25")
        XCTAssertFalse(subtitle.contains(":"))
    }
}
