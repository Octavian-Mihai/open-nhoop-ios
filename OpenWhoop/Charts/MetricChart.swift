import SwiftUI
import Charts

// MARK: - MetricChart
// Unified, reusable chart component used by TrendChartCard (compact) and MetricDetailView (full).
// iOS 16-safe: uses .chartOverlay + GeometryReader for tap selection.
// Overflow fix: .clipped() + .chartPlotStyle(.clipped()) + padded y-scale.

struct MetricChart: View {

    let series: [TrendPoint]
    let kind: MetricKind
    var showAxes: Bool = true
    var showSelection: Bool = false
    var yDomain: ClosedRange<Double>? = nil
    /// Wall-clock bin width for raw HR display (seconds). Ignored for daily metrics.
    var hrBinIntervalSeconds: Int = HRChartPresentation.compactBinSeconds
    /// Resting / max HR for Edwards zone coloring (`.rawHR` only).
    var hrResting: Double = Strain.defaultRestingHR
    var hrMax: Double = Strain.defaultMaxHR()
    @Binding var selected: TrendPoint?

    // MARK: - Body

    var body: some View {
        if displaySeries.count < 2 {
            emptyChart
        } else if kind == .rawHR {
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                chartBody
                hrZoneLegend
            }
        } else {
            chartBody
        }
    }

    // MARK: - Display series (raw HR is bucketed for readability)

    private var displaySeries: [TrendPoint] {
        guard kind == .rawHR else { return series }
        return HRChartPresentation.bucket(points: series, intervalSeconds: hrBinIntervalSeconds)
    }

    private var hrRuns: [HRChartPresentation.HRRun] {
        guard kind == .rawHR else { return [] }
        return HRChartPresentation.zoneRuns(
            points: displaySeries,
            binSeconds: hrBinIntervalSeconds,
            restingHR: hrResting,
            maxHR: hrMax)
    }

    private var emptyChart: some View {
        HStack {
            Spacer()
            VStack(spacing: WH.Spacing.xs) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                Text("Not enough data")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
            Spacer()
        }
        .frame(height: showAxes ? 200 : 100)
    }

    // MARK: - Effective y-domain with padding

    private var effectiveDomain: ClosedRange<Double> {
        if kind == .rawHR {
            return yDomain ?? HRChartPresentation.yDomain(for: displaySeries)
        }

        let base = yDomain ?? kind.fixedYDomain
        let vals = displaySeries.map(\.value)
        let minVal = vals.min() ?? 0
        let maxVal = vals.max() ?? 1

        let lo: Double
        let hi: Double
        if let b = base {
            lo = b.lowerBound
            hi = b.upperBound
        } else {
            let pad = max((maxVal - minVal) * 0.13, 1.0)
            lo = max(0, minVal - pad)
            hi = maxVal + pad
        }
        return lo...hi
    }

    // MARK: - Main chart

    @ViewBuilder
    private var chartBody: some View {
        let dom = effectiveDomain
        let color = kind.color

        Chart {
            // Recovery zone bands (drawn first, behind the data)
            if kind.hasRecoveryBands {
                recoveryBands(dom: dom)
            }

            // Data marks
            switch kind.markType {
            case .line:
                if kind == .rawHR {
                    hrLineMarks()
                } else {
                    lineMarks(color: color)
                }
            case .bar:
                barMarks(color: color)
            }

            // Selection highlight
            if showSelection, let sel = selected {
                RuleMark(x: .value("Sel", sel.date))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(
                    x: .value("Date", sel.date),
                    y: .value(kind.title, sel.value)
                )
                .foregroundStyle(kind == .rawHR ? hrZoneColor(Strain.edwardsZone(
                    bpm: sel.value, restingHR: hrResting, maxHR: hrMax)) : color)
                .symbolSize(100)
                .annotation(position: .top, alignment: .center, spacing: 4) {
                    selectionCallout(point: sel)
                }
            }
        }
        .chartYScale(domain: dom)
        .chartForegroundStyleScale(
            domain: kind == .rawHR ? hrRuns.map(\.id) : [],
            range: kind == .rawHR ? hrRuns.map { hrZoneColor($0.zone) } : []
        )
        .chartXAxis { xAxisContent }
        .chartYAxis { yAxisContent }
        .chartPlotStyle { plot in
            plot
                .background(WH.Color.surface2)
                .clipped()
        }
        .clipped()
        // iOS-16 tap / drag-to-scrub
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard showSelection else { return }
                                handleTap(location: value.location, proxy: proxy, geometry: geo)
                            }
                    )
            }
        }
        .chartLegend(.hidden)
    }

    // MARK: - Recovery zone bands

    @ChartContentBuilder
    private func recoveryBands(dom: ClosedRange<Double>) -> some ChartContent {
        // Green zone: 67–100
        RectangleMark(
            xStart: .value("s", displaySeries.first!.date),
            xEnd:   .value("e", displaySeries.last!.date),
            yStart: .value("lo", min(67.0, dom.upperBound)),
            yEnd:   .value("hi", dom.upperBound)
        )
        .foregroundStyle(WH.Color.recoveryGreen.opacity(0.07))

        // Yellow zone: 34–67
        RectangleMark(
            xStart: .value("s", displaySeries.first!.date),
            xEnd:   .value("e", displaySeries.last!.date),
            yStart: .value("lo", min(34.0, dom.upperBound)),
            yEnd:   .value("hi", min(67.0, dom.upperBound))
        )
        .foregroundStyle(WH.Color.recoveryYellow.opacity(0.07))

        // Red zone: 0–34
        RectangleMark(
            xStart: .value("s", displaySeries.first!.date),
            xEnd:   .value("e", displaySeries.last!.date),
            yStart: .value("lo", dom.lowerBound),
            yEnd:   .value("hi", min(34.0, dom.upperBound))
        )
        .foregroundStyle(WH.Color.recoveryRed.opacity(0.07))
    }

    // MARK: - Line marks

    @ChartContentBuilder
    private func hrLineMarks() -> some ChartContent {
        let runs = hrRuns
        ForEach(runs) { run in
            ForEach(run.points) { pt in
                AreaMark(
                    x: .value("Date", pt.date),
                    y: .value(kind.title, pt.value)
                )
                .foregroundStyle(by: .value("Run", run.id))
                .interpolationMethod(.catmullRom)
                .opacity(0.32)
            }
        }
        ForEach(runs) { run in
            ForEach(run.points) { pt in
                LineMark(
                    x: .value("Date", pt.date),
                    y: .value(kind.title, pt.value)
                )
                .foregroundStyle(by: .value("Run", run.id))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
        }
    }

    @ChartContentBuilder
    private func lineMarks(color: Color) -> some ChartContent {
        // Faint gradient area
        ForEach(displaySeries) { pt in
            AreaMark(
                x: .value("Date", pt.date),
                y: .value(kind.title, pt.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.28), color.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        // Line
        ForEach(displaySeries) { pt in
            LineMark(
                x: .value("Date", pt.date),
                y: .value(kind.title, pt.value)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
    }

    // MARK: - Bar marks

    @ChartContentBuilder
    private func barMarks(color: Color) -> some ChartContent {
        // Constrain bar width based on point count to prevent overflow
        let barWidth: MarkDimension = barWidthForCount(displaySeries.count)
        ForEach(displaySeries) { pt in
            BarMark(
                x: .value("Date", pt.date),
                y: .value(kind.title, pt.value),
                width: barWidth
            )
            .foregroundStyle(color.opacity(0.85))
            .cornerRadius(3)
        }
    }

    private func barWidthForCount(_ count: Int) -> MarkDimension {
        // Keep bars narrow enough to never bleed: cap at ~12pt max
        switch count {
        case ..<8:  return .fixed(14)
        case ..<15: return .fixed(10)
        case ..<31: return .fixed(7)
        case ..<91: return .fixed(4)
        default:    return .fixed(3)
        }
    }

    // MARK: - Adaptive x-axis helpers

    private var seriesSpanSeconds: TimeInterval {
        guard let first = displaySeries.first?.date, let last = displaySeries.last?.date else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }

    /// Number of calendar days the series spans (first point to last point).
    private var seriesSpanDays: Int {
        guard seriesSpanSeconds > 0 else { return 0 }
        return max(1, Int(seriesSpanSeconds / 86_400) + 1)
    }

    /// Desired tick count chosen so that no two ticks land on the same calendar day.
    /// With N days of data the axis will place at most N ticks; we also cap at 5
    /// to keep labels readable on narrow screens.
    private var xAxisDesiredCount: Int {
        if kind == .rawHR {
            if seriesSpanSeconds <= 36 * 3_600 { return 6 }
            if seriesSpanSeconds <= 7 * 86_400 { return 5 }
        }
        let days = seriesSpanDays
        return min(5, max(2, days))
    }

    private func xAxisDateLabel(_ date: Date) -> String {
        ChartDateFormatting.axisLabel(date: date, spanSeconds: seriesSpanSeconds, kind: kind)
    }

    // MARK: - Axis content

    @AxisContentBuilder
    private var xAxisContent: some AxisContent {
        if showAxes {
            AxisMarks(values: .automatic(desiredCount: xAxisDesiredCount)) { value in
                AxisGridLine()
                    .foregroundStyle(WH.Color.separator.opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisDateLabel(date))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
        } else {
            AxisMarks { _ in }   // hide in compact mode
        }
    }

    @AxisContentBuilder
    private var yAxisContent: some AxisContent {
        if showAxes {
            if kind == .rawHR {
                let ticks = HRChartPresentation.yTickValues(domain: effectiveDomain)
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine()
                        .foregroundStyle(WH.Color.separator)
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(kind.formatShort(d))
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(WH.Color.textSecondary)
                        }
                    }
                }
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(WH.Color.separator)
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(kind.formatShort(d))
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(WH.Color.textSecondary)
                        }
                    }
                }
            }
        } else {
            AxisMarks(position: .leading) { _ in }
        }
    }

    // MARK: - Selection callout

    private func selectionCallout(point: TrendPoint) -> some View {
        VStack(spacing: 2) {
            Text(kind.format(point.value))
                .font(.system(size: kind == .rawHR ? 18 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            Text(ChartDateFormatting.selectionSubtitle(date: point.date, kind: kind))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(WH.Color.textSecondary)
        }
        .padding(.horizontal, WH.Spacing.sm)
        .padding(.vertical, WH.Spacing.xs)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous)
                .stroke(WH.Color.separator, lineWidth: 0.5)
        )
    }

    // MARK: - Tap handling (iOS 16)

    private func handleTap(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard !displaySeries.isEmpty else { return }
        let origin = geometry[proxy.plotAreaFrame].origin
        let x = location.x - origin.x

        if let tappedDate: Date = proxy.value(atX: x) {
            selected = displaySeries.min(by: {
                abs($0.date.timeIntervalSince(tappedDate)) < abs($1.date.timeIntervalSince(tappedDate))
            })
        } else {
            // Fallback: fractional position
            let fraction = max(0, min(1, location.x / geometry.size.width))
            let idx = min(displaySeries.count - 1, Int((fraction * Double(displaySeries.count - 1)).rounded()))
            selected = displaySeries[idx]
        }
    }

    // MARK: - HR zone colors / legend

    private func hrZoneColor(_ zone: Int) -> Color {
        switch zone {
        case 0: return WH.Color.textSecondary
        case 1: return WH.Color.teal
        case 2: return WH.Color.recoveryGreen
        case 3: return WH.Color.recoveryYellow
        case 4: return Color(hex: "#FF8C00")
        case 5: return WH.Color.recoveryRed
        default: return WH.Color.textSecondary
        }
    }

    private var hrZoneLegend: some View {
        HStack(spacing: WH.Spacing.sm) {
            ForEach(0..<6, id: \.self) { zone in
                HStack(spacing: 4) {
                    Circle()
                        .fill(hrZoneColor(zone))
                        .frame(width: 7, height: 7)
                    Text(HRChartPresentation.zoneLabel(zone))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(WH.Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
