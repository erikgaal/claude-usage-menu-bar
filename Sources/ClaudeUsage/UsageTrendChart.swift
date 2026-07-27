import Charts
import SwiftUI

/// Burndown of one multi-day limit across its current window: quota *left* on
/// the y-axis, descending toward the floor. Three things are drawn, and nothing
/// else:
///
/// - **Recorded** — a solid line with a wash beneath it (the quota still in
///   hand), from the first sample recorded inside this window to the newest
///   one. The x-axis is the whole window, so a line that starts on Thursday
///   says plainly that nothing was recorded before then rather than pretending
///   the week began when polling did.
/// - **Projected** — a dashed continuation at the same fitted pace the panel's
///   own "on pace to run out" caption uses, so the two can never disagree. It
///   flattens along the floor once the pace reaches zero; that flat stretch is
///   the runway that would be spent locked out.
/// - **Even pace** — the hairline diagonal from a full quota at the window's
///   start to zero at its reset: the pace that spends the budget exactly.
///   Below the line is overspending, above it is headroom.
///
/// History stores utilization (percent *used*), which is also what every bar
/// and number in the panel shows; `remaining(_:)` below is the single place the
/// two framings meet, and the caption states both so the chart can always be
/// tied back to the bar above it.
///
/// The line wears the same threshold color as the limit's bar (`LimitRow`) —
/// keyed to percent used, so a red chart and a red bar always mean the same
/// thing even though the chart plots the complement.
struct UsageTrendChart: View {
    let limit: LimitStatus
    let trend: UsageTrend
    /// Names the limit above the chart. Only needed when an account has more
    /// than one multi-day window (a Weekly plus a model-scoped one), where an
    /// unlabeled second chart would be a guessing game.
    var showsTitle: Bool = false

    var body: some View {
        // Enough air that the axis label above the plot doesn't crowd the
        // topmost y tick, which sits only a few points below it.
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.name) trend. \(summary)")
    }

    // MARK: Header

    /// Names the axis — the one thing a burndown must not leave ambiguous,
    /// since the panel's bars and numbers all count the other way — and keys
    /// the reference line. Past-vs-future needs no key: the solid line becomes
    /// dashed at "now".
    private var header: some View {
        HStack(spacing: 6) {
            Text(showsTitle ? "\(limit.name) · quota left" : "quota left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 12, height: 1)
            Text("even pace")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(evenPace) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Left", point.percent),
                    series: .value("Series", "pace")
                )
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.secondary.opacity(0.45))
            }

            ForEach(recorded) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Left", point.percent)
                )
                // A wash that fades out downwards, not a filled block: a flat
                // tint goes muddy over the dark appearance's surface and
                // competes with the even-pace line crossing it.
                .foregroundStyle(
                    .linearGradient(
                        colors: [color.opacity(0.20), color.opacity(0.01)],
                        startPoint: .top, endPoint: .bottom))
            }

            ForEach(recorded) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Left", point.percent),
                    series: .value("Series", "recorded")
                )
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(color)
            }

            ForEach(projected) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Left", point.percent),
                    series: .value("Series", "projected")
                )
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 3]))
                .foregroundStyle(color.opacity(0.6))
            }

            // "You are here": also the only mark visible when a window has
            // just reset and a single sample has landed in it.
            PointMark(
                x: .value("Time", trend.latest.date),
                y: .value("Left", remaining(trend.latest).percent)
            )
            .symbolSize(50)
            .foregroundStyle(color)
        }
        .chartXScale(domain: trend.windowStart...trend.windowEnd)
        .chartYScale(domain: 0...100)
        // Axis text takes an explicit gray: inside `Chart`, `.tertiary`
        // resolves against the plot's own palette and comes out accent-blue,
        // which would read as a fourth mark.
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) {
                AxisGridLine().foregroundStyle(Self.gridColor)
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(Self.axisTextColor)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) {
                AxisGridLine().foregroundStyle(Self.gridColor)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Self.axisTextColor)
            }
        }
        .frame(height: 88)
    }

    /// Hairline grid, one step off the surface in both appearances.
    private static let gridColor = Color.primary.opacity(0.09)
    private static let axisTextColor = Color.secondary.opacity(0.8)

    // MARK: Series

    /// The stored series carry utilization; the chart plots what's left. This
    /// is the only conversion in the view, so the two framings can't drift.
    private func remaining(_ point: UsageTrend.Point) -> UsageTrend.Point {
        UsageTrend.Point(date: point.date, percent: 100 - point.percent)
    }

    private var recorded: [UsageTrend.Point] { trend.recorded.map(remaining) }
    private var projected: [UsageTrend.Point] { trend.projected.map(remaining) }

    /// The two ends of the even-pace diagonal: a full quota at the window's
    /// start, nothing left at its reset.
    private var evenPace: [UsageTrend.Point] {
        [
            UsageTrend.Point(date: trend.windowStart, percent: 100),
            UsageTrend.Point(date: trend.windowEnd, percent: 0),
        ]
    }

    /// Matches `LimitRow`'s thresholds so the chart and the bar above it are
    /// never two different colors for one number.
    private var color: Color {
        switch limit.percent {
        case 90...: return .red
        case 70..<90: return .orange
        default: return .green
        }
    }

    // MARK: Summary

    private var summary: String {
        Self.summary(for: trend, percent: limit.percent)
    }

    /// The line under the chart. It opens with both framings — the bar above
    /// reads "71%", the dot on the chart sits at 29 — then reports where this
    /// pace lands, the one thing no other line in the panel says.
    static func summary(for trend: UsageTrend, percent: Double) -> String {
        let now = "\(Int(percent.rounded()))% used · \(Int((100 - percent).rounded()))% left"
        // `projectedAtReset` is only set once a pace was fittable, so it alone
        // decides whether there's a forecast to report.
        guard let atReset = trend.projectedAtReset else {
            return "\(now) · not enough history to project yet"
        }
        if let exhaustsAt = trend.exhaustsAt {
            return "\(now) · on pace to run out "
                + AccountSection.exhaustionTimeText(exhaustsAt)
        }
        // Stated in the axis's own terms, so the figure matches where the
        // dashed line lands instead of making the reader subtract.
        return "\(now) · on pace to land at \(Int((100 - atReset).rounded()))%"
    }
}
