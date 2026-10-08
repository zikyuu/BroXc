import SwiftUI
import Charts

// MARK: - Radial spending map
//
//  angle  = how much was spent (approximately: every wedge gets a minimum so a small category stays tappable)
//  radius = spend against the green reference (budget, else usual) - beyond the green line means over
//  colour = which category, always the same one; a wedge is never recoloured to judge it

struct SectorShape: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var start: Double   // radians, clockwise from +x
    var end: Double

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
        let reference: Double?
        let referenceIsBudget: Bool
        let usual: Double?
        let muted: Bool
        let route: Route
    }

    let home: HomeData
    let wedges: [Wedge]
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let u = size / 316                      // the design is drawn on a 316-unit square
            let c = CGPoint(x: size / 2, y: size / 2)
            let rIn = 74 * u, rRef = 122 * u
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
                    let ratio = wedge.reference.map { wedge.actual / $0 } ?? 1
                    let outer = rIn + (rRef - rIn) * min(1.55, max(0.5, ratio))
                    let inset = 5 * u
                    NavigationLink(value: wedge.route) {
                        ZStack {
                            SectorShape(innerRadius: rIn + inset, outerRadius: outer - inset, start: a0 + 0.04, end: a1 - 0.04)
                                .fill(wedge.color)
                            SectorShape(innerRadius: rIn + inset, outerRadius: outer - inset, start: a0 + 0.04, end: a1 - 0.04)
                                .stroke(wedge.color, style: StrokeStyle(lineWidth: inset * 2, lineJoin: .round))
                            if wedge.referenceIsBudget, let usual = wedge.usual, let reference = wedge.reference {
                                // where usual sits, when the reference is a budget (otherwise usual *is* the green line)
                                let ru = rIn + (rRef - rIn) * min(1.55, max(0.5, usual / reference))
                                Path { p in
                                    let steps = 12
                                    for i in 0...steps {
                                        let t = (a0 + 0.06) + ((a1 - 0.06) - (a0 + 0.06)) * Double(i) / Double(steps)
                                        let pt = CGPoint(x: size / 2 + ru * cos(t), y: size / 2 + ru * sin(t))
                                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                                    }
                                }.stroke(Color(hex: "3d7bff"), style: StrokeStyle(lineWidth: 3.5 * u, lineCap: .round))
                            }
                            label(for: wedge, mid: (a0 + a1) / 2, radius: (rIn + outer) / 2 + 2 * u, center: c, wide: (a1 - a0) > 0.5, u: u)
                        }
                        .frame(width: size, height: size)
                        .contentShape(SectorShape(innerRadius: rIn, outerRadius: outer, start: a0, end: a1))
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(appeared ? 1 : 0.8).opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(Double(index) * 0.045), value: appeared)
                    .accessibilityLabel("\(wedge.name) \(Money.whole(wedge.actual))")
                }

                // the green line: where a category lands when it sits exactly on budget / usual - slightly wavy, hand-drawn
                Path { p in
                    for i in 0...180 {
                        let t = Double(i) / 180 * 2 * Double.pi
                        let r = rRef + 2.2 * u * sin(t * 22)
                        let pt = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                    p.closeSubpath()
                }
                .stroke(Color(hex: "8fe3a9"), style: StrokeStyle(lineWidth: 2.6 * u, lineJoin: .round))
                .allowsHitTesting(false)

                centre(u: u)
            }
            .frame(width: size, height: size)
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
            if let icon = wedge.icon, wide { Text(icon).font(.system(size: 14 * u)) }
            Text(Money.whole(wedge.actual)).font(.system(size: 12 * u, weight: .heavy, design: .rounded)).foregroundStyle(Color(hex: "2b211a"))
            if wedge.muted && wide { Text(wedge.name.uppercased()).font(.system(size: 8 * u, weight: .bold)).tracking(0.4).foregroundStyle(Color(hex: "6b5f52")) }
        }
        .position(x: x, y: y)
        .allowsHitTesting(false)
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
            VStack(spacing: 1) {
                Text(home.dayLabel).font(.system(size: 11 * u, weight: .semibold, design: .rounded)).foregroundStyle(Theme.muted)
                Text(Money.whole(home.total)).font(.system(size: 21 * u, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                Text("your spending").font(.system(size: 10 * u, design: .rounded)).foregroundStyle(Theme.muted)
            }.frame(width: ring * 1.55)
        }
        .allowsHitTesting(false)
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
