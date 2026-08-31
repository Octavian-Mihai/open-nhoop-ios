import Foundation

// MARK: - ChartDateFormatting
// Kind-aware axis and selection date labels for MetricChart.

enum ChartDateFormatting {

    private static var calendar: Calendar { Calendar.current }

    private static let shortDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d"
        return f
    }()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f
    }()

    private static let mediumDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    private static let hourFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h a"
        return f
    }()

    private static let weekdayHourFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE h a"
        return f
    }()

    private static let fullDateTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    /// X-axis tick label for a point at `date`, given series span and metric kind.
    static func axisLabel(date: Date, spanSeconds: TimeInterval, kind: MetricKind) -> String {
        switch kind {
        case .rawHR:
            if spanSeconds <= 36 * 3_600 {
                return hourFmt.string(from: date)
            }
            if spanSeconds <= 7 * 86_400 {
                return weekdayHourFmt.string(from: date)
            }
            return shortDateFmt.string(from: date)
        default:
            let spanDays = max(1, Int(spanSeconds / 86_400) + 1)
            return spanDays > 30 ? monthFmt.string(from: date) : shortDateFmt.string(from: date)
        }
    }

    /// Selection callout secondary line (below the value).
    static func selectionSubtitle(date: Date, kind: MetricKind) -> String {
        switch kind {
        case .rawHR:
            if hasNonMidnightTime(date) {
                return fullDateTimeFmt.string(from: date)
            }
            return mediumDateFmt.string(from: date)
        default:
            return mediumDateFmt.string(from: date)
        }
    }

    private static func hasNonMidnightTime(_ date: Date) -> Bool {
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 || (comps.second ?? 0) != 0
    }
}
