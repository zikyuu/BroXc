import SwiftUI
import Charts

// MARK: - Radial spending map
//
//  angle  = how much was spent (approximately: every wedge gets a minimum so a small category stays tappable)
//  radius = spend against what's usual by this point in the month - past the dashed ring means ahead of usual
//  tap    = select a slice: it grows to its budget (lighter colour to the budget edge, filled to what's spent)
//  colour = which category, always the same one; a wedge is never recoloured to judge it

struct SectorShape: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var start: Double   // radians, clockwise from +x
    var end: Double

    /// So a slice can morph between months instead of jumping: its angles and radii are interpolated.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(innerRadius, outerRadius), AnimatablePair(start, end)) }
        set { innerRadius = newValue.first.first; outerRadius = newValue.first.second; start = newValue.second.first; end = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let steps = max(2, Int(((end - start) / 0.03).rounded(.up)))
        func point(_ r: CGFloat, _ t: Double) -> CGPoint { CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t)) }
        var path = Path()
        for i in 0...steps {
            let p = point(outerRadius, start + (end - start) * Double(i) / Double(steps))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        for i in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: point(innerRadius, start + (end - start) * Double(i) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }
}

struct RadialChart: View {
    struct Wedge: Identifiable {
        let id: String
        let name: String
        let icon: String?
        let color: Color
        let actual: Double
        let usual: Double?
        let budget: Double?
        let muted: Bool
        let route: Route
    }

    let home: HomeData
    let wedges: [Wedge]
    /// The selected slice's id, or `RadialChart.totalID` for the centre (the whole month against the total budget).
    @Binding var selection: String?
    @State private var appeared = false

    static let totalID = "total"
    /// Where a slice reaches when it's selected and shows its budget; everything else tops out inside this.
    private static let budgetEdge: CGFloat = 150

    /// A wedge juts out or in by spending so far against what's usual *by this point in the month*: 11 days in, a quarter of
    /// a usual month's food is on pace, not under. A finished month compares whole to whole. Very early in the month the
    /// scale is held up, since two days of shopping say little about the rate.
    private var paceScale: Double {
        guard home.isCurrent, home.elapsedFraction < 1 else { return 1 }
        return max(home.elapsedFraction, 0.25)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let u = size / 336                      // the design is drawn on a 336-unit square (the ring reaches ~160 units at most)
            let c = CGPoint(x: size / 2, y: size / 2)
            let rIn = 68 * u, rRef = 126 * u              // a thicker band, so each slice has room for its icon and amount
            let rBudget = Self.budgetEdge * u
            let totalMode = selection == Self.totalID && home.budgetTotal != nil
            ZStack {
                if wedges.isEmpty {
                    Circle().stroke(Theme.line, style: StrokeStyle(lineWidth: 22 * u, lineCap: .round, dash: [3, 9]))
                        .frame(width: (rIn + rRef), height: (rIn + rRef))
                }
                let total = wedges.reduce(0) { $0 + $1.actual }
                let n = Double(wedges.count)
                let gap = 0.03
                let minAngle = n > 0 ? min(0.46, Double.pi / n) : 0     // no wedge thinner than ~26 degrees (fewer if crowded)
                let spare = 2 * Double.pi - n * gap - n * minAngle      // the rest is shared out by real amount
                let spans = wedges.map { minAngle + spare * ($0.actual / max(total, 0.0001)) }
                let starts = spans.indices.map { i in -Double.pi / 2 + spans[..<i].reduce(0, +) + gap * Double(i) }

                ForEach(Array(wedges.enumerated()), id: \.element.id) { index, wedge in
                    let a0 = starts[index] + gap / 2, a1 = starts[index] + spans[index] - gap / 2
                    let isSelected = selection == wedge.id
                    let ratio = wedge.usual.map { wedge.actual / ($0 * paceScale) } ?? 1
                    let usualOuter = rIn + (rRef - rIn) * min(1.55, max(0.5, ratio))
                    // selected with a budget: the slice is drawn on the budget's scale instead - filled to what's spent
                    let budgetShare = wedge.budget.flatMap { $0 > 0 ? wedge.actual / $0 : nil }
                    let showsBudget = isSelected && budgetShare != nil
                    let outer = showsBudget ? rIn + (rBudget - rIn) * min(1, max(0.2, budgetShare ?? 0)) : usualOuter
                    let inset = 5 * u
                    let faded = selection != nil && !isSelected
                    // a tap (not a link) selects the slice, so a sideways swipe over the chart changes the month instead
                    Group {
                        ZStack {
                            if showsBudget {
                                ZStack {
                                    SectorShape(innerRadius: rIn + inset, outerRadius: rBudget - inset, start: a0 + 0.04, end: a1 - 0.04).fill(wedge.color)
                                    SectorShape(innerRadius: rIn + inset, outerRadius: rBudget - inset, start: a0 + 0.04, end: a1 - 0.04)
                                        .stroke(wedge.color, style: StrokeStyle(lineWidth: inset * 2, lineJoin: .round))
                                }
                                .compositingGroup().opacity(0.26)
                                .transition(.opacity)
                            }
                            SectorShape(innerRadius: rIn + inset, outerRadius: outer - inset, start: a0 + 0.04, end: a1 - 0.04)
                                .fill(wedge.color)
                            SectorShape(innerRadius: rIn + inset, outerRadius: outer - inset, start: a0 + 0.04, end: a1 - 0.04)
                                .stroke(wedge.color, style: StrokeStyle(lineWidth: inset * 2, lineJoin: .round))
                            label(for: wedge, mid: (a0 + a1) / 2, radius: (rIn + outer) / 2 + 2 * u, center: c, wide: (a1 - a0) > 0.5, u: u)
                        }
                        .frame(width: size, height: size)
                        .contentShape(SectorShape(innerRadius: rIn, outerRadius: showsBudget ? rBudget : outer, start: a0, end: a1))
                    }
                    .opacity(faded ? (totalMode ? 0.55 : 0.3) : 1)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: selection)
                    .onTapGesture { selection = isSelected ? nil : wedge.id }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .scaleEffect(appeared ? 1 : 0.8).opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(Double(index) * 0.045), value: appeared)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("\(wedge.name) \(Money.whole(wedge.actual))")
                }

                // the whole month against the total budget: a gauge around the outside, the slices stepping back
                if totalMode, let budget = home.budgetTotal {
                    let share = home.total / budget
                    let mid = 157 * u, width = 14 * u
                    ZStack {
                        Circle().stroke(Theme.accent.opacity(0.18), lineWidth: width)
                        Circle().trim(from: 0, to: min(max(share, 0.004), 1))
                            .stroke(share > 1 ? (Theme.paceColors[.over] ?? Theme.accent) : Theme.accent, style: StrokeStyle(lineWidth: width))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: mid * 2, height: mid * 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // the dashed ring: where a category lands when it sits exactly on its usual pace. Only once there is a usual to show.
                if home.usualMonths > 0 {
                    Circle()
                        .stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.2 * u, lineJoin: .round, dash: [3 * u, 5 * u]))
                        .frame(width: rRef * 2, height: rRef * 2)
                        .allowsHitTesting(false)
                }

                centre(u: u)
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: totalMode)
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func label(for wedge: Wedge, mid: Double, radius: CGFloat, center: CGPoint, wide: Bool, u: CGFloat) -> some View {
        let x = center.x + radius * cos(mid), y = center.y + radius * sin(mid)
        VStack(spacing: 0) {
            if let icon = wedge.icon { Glyph(symbol: icon, size: (wide ? 14 : 10) * u).environment(\.colorScheme, .light) }
            Text(Money.whole(wedge.actual)).font(.system(size: 12.5 * u, weight: .heavy, design: .rounded)).foregroundStyle(Color(hex: "2b211a"))
            if wedge.muted && wide { Text(wedge.name.uppercased()).font(.system(size: 8 * u, weight: .bold)).tracking(0.4).foregroundStyle(Color(hex: "6b5f52")) }
        }
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }

    /// How the mascot looks at the pace: happy on track, worried when nearing the limit, sad over it.
    private var paceMascot: String {
        switch home.status { case .good: return "mascot-expr-happy"; case .watch: return "mascot-expr-concerned"; case .over: return "mascot-expr-sad"; case .neutral: return "mascot-expr-default" }
    }

    @ViewBuilder
    private func centre(u: CGFloat) -> some View {
        let ring = 56 * u
        ZStack {
            Circle().fill(Theme.surface).frame(width: ring * 2, height: ring * 2)
            Circle().stroke(Theme.line, lineWidth: 8 * u).frame(width: (ring - 2 * u) * 2, height: (ring - 2 * u) * 2)
            if home.elapsedFraction > 0 {
                Circle().trim(from: 0, to: min(home.elapsedFraction, 0.999))
                    .stroke(Theme.paceColors[home.status] ?? .gray, style: StrokeStyle(lineWidth: 8 * u, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: (ring - 2 * u) * 2, height: (ring - 2 * u) * 2)
            }
            VStack(spacing: 0) {
                Image(paceMascot).resizable().scaledToFit().frame(height: 30 * u).accessibilityHidden(true)
                Text(home.dayLabel).font(.system(size: 11 * u, weight: .semibold, design: .rounded)).foregroundStyle(Theme.muted)
                Text(Money.whole(home.total)).font(.system(size: 21 * u, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText())
            }.frame(width: ring * 1.55)
        }
        .contentShape(Circle())
        .onTapGesture { if home.budgetTotal != nil { selection = selection == Self.totalID ? nil : Self.totalID } }
        .accessibilityAddTraits(home.budgetTotal != nil ? .isButton : [])
    }
}

// MARK: - Line charts

/// Small, axis-free sparkline of the month so far, last month's pace, and where it's heading.
struct PaceChart: View {
    let actual: [Double]
    let usual: [Double]
    let projected: Double
    let days: Int
    let today: Int
    let showProjection: Bool

    var body: some View {
        let top = max(1, projected, usual.last ?? 0, actual.last ?? 0) * 1.05
        Chart {
            ForEach(Array(usual.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("Day", i + 1), y: .value("Usual", v), series: .value("Series", "usual"))
                    .foregroundStyle(Theme.mutedLine).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(Array(actual.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("Day", i + 1), y: .value("Spent", v), series: .value("Series", "area"))
                    .foregroundStyle(Theme.accent.opacity(0.14))
                LineMark(x: .value("Day", i + 1), y: .value("Spent", v), series: .value("Series", "actual"))
                    .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if showProjection, let last = actual.last, today < days {
                LineMark(x: .value("Day", today), y: .value("Projected", last), series: .value("Series", "proj"))
                    .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                LineMark(x: .value("Day", days), y: .value("Projected", projected), series: .value("Series", "proj"))
                    .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...top).chartXScale(domain: 1...max(days, 2))
        .frame(height: 84)
    }
}

/// The full chart for Trends: this month's cumulative spend against usual, or monthly totals, with tap-to-read.
struct TrendChart: View {
    enum Mode { case daily(actual: [Double], usual: [Double], days: Int, today: Int), monthly([MonthPoint], usual: Double?) }
    let mode: Mode
    @State private var selected: Int?

    var body: some View {
        Group {
            switch mode {
            case let .daily(actual, usual, days, today): daily(actual, usual, days, today)
            case let .monthly(points, usual): monthly(points, usual)
            }
        }
        .frame(height: 200)
    }

    @ViewBuilder
    private func daily(_ actual: [Double], _ usual: [Double], _ days: Int, _ today: Int) -> some View {
        let top = max(1, usual.max() ?? 0, actual.max() ?? 0) * 1.1
        Chart {
            ForEach(Array(usual.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("Day", i + 1), y: .value("Usual", v), series: .value("S", "usual"))
                    .foregroundStyle(Theme.mutedLine).lineStyle(StrokeStyle(lineWidth: 2.2))
            }
            ForEach(Array(actual.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("Day", i + 1), y: .value("Spent", v), series: .value("S", "area")).foregroundStyle(Theme.accent.opacity(0.14))
                LineMark(x: .value("Day", i + 1), y: .value("Spent", v), series: .value("S", "actual"))
                    .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let last = actual.last, today > 0 {
                PointMark(x: .value("Day", today), y: .value("Spent", last)).foregroundStyle(Theme.accent).symbolSize(70)
            }
            if let day = selected {
                RuleMark(x: .value("Day", day)).foregroundStyle(Theme.mutedLine)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        let spent = day - 1 < actual.count ? actual[day - 1] : nil
                        let usualValue = day - 1 < usual.count ? usual[day - 1] : nil
                        Text("Day \(day): \(Money.whole(spent ?? usualValue ?? 0))" + (usualValue.map { " · usual \(Money.whole($0))" } ?? ""))
                            .font(.rounded(11, .bold)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.surface, in: Capsule()).overlay(Capsule().stroke(Theme.line))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: 0...top).chartXScale(domain: 1...max(days, 2))
        .chartXAxis { AxisMarks(values: [1, 8, 15, 22, days].filter { $0 <= days }) { AxisValueLabel().font(.rounded(10)) } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.line)
            AxisValueLabel { if let v = value.as(Double.self) { Text(Money.whole(v)).font(.rounded(10)) } }
        } }
    }

    @ViewBuilder
    private func monthly(_ points: [MonthPoint], _ usual: Double?) -> some View {
        let top = max(1, points.map(\.total).max() ?? 0, usual ?? 0) * 1.15
        Chart {
            if let usual { RuleMark(y: .value("Usual", usual)).foregroundStyle(Theme.mutedLine).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5])) }
            ForEach(points) { p in
                AreaMark(x: .value("Month", p.month.id), y: .value("Spent", p.total), series: .value("S", "area")).foregroundStyle(Theme.accent.opacity(0.12))
                LineMark(x: .value("Month", p.month.id), y: .value("Spent", p.total), series: .value("S", "line"))
                    .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Month", p.month.id), y: .value("Spent", p.total)).foregroundStyle(Theme.accent)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisValueLabel { if let id = value.as(String.self), let p = points.first(where: { $0.month.id == id }) { Text(points.count > 8 ? "\(p.month.shortLabel) \(String(p.month.year).suffix(2))" : p.month.shortLabel).font(.rounded(10)) } }
        } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.line)
            AxisValueLabel { if let v = value.as(Double.self) { Text(Money.whole(v)).font(.rounded(10)) } }
        } }
    }
}

struct WeekdayBars: View {
    let points: [WeekdayPoint]
    var body: some View {
        Chart(points) { p in
            BarMark(x: .value("Day", p.label), y: .value("Average", p.average)).foregroundStyle(Theme.accent).cornerRadius(6)
        }
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks { AxisValueLabel().font(.rounded(11)) } }
        .frame(height: 110)
    }
}

// MARK: - Semi-proportional tiles
//
// A pure treemap would make a $2 category a sliver nobody can tap. Each tile's weight is floored at a share
// of the total, so size still reflects importance but never drops below a usable minimum.

enum TileLayout {
    struct Rect { let index: Int; let x: Double, y: Double, w: Double, h: Double }

    static func layout(_ totals: [Double], minShare: Double = 0.09) -> [Rect] {
        let sum = max(totals.reduce(0) { $0 + max($1, 0) }, 0.0001)
        let weights = totals.enumerated().map { (index: $0.offset, weight: max($0.element, sum * ($0.element > 0 ? minShare : minShare * 0.75))) }
        var rects: [Rect] = []
        func split(_ list: ArraySlice<(index: Int, weight: Double)>, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            guard let first = list.first else { return }
            if list.count == 1 { rects.append(Rect(index: first.index, x: x, y: y, w: w, h: h)); return }
            let total = list.reduce(0) { $0 + $1.weight }
            var acc = 0.0, cut = 1
            for (i, item) in list.dropLast().enumerated() { acc += item.weight; cut = i + 1; if acc >= total / 2 { break } }
            let left = list.prefix(cut), right = list.dropFirst(cut)
            let share = left.reduce(0) { $0 + $1.weight } / total
            if w >= h { split(left, x, y, w * share, h); split(right, x + w * share, y, w * (1 - share), h) }
            else { split(left, x, y, w, h * share); split(right, x, y + h * share, w, h * (1 - share)) }
        }
        split(weights[...], 0, 0, 1, 1)
        return rects
    }
}
