import SwiftUI
import SwiftData

/// Home: the radial spending map, then the context cards (This Month, At This Pace, Needs a Look,
/// Compared With Usual) and recent activity.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @Environment(AppNavigation.self) private var navigation
    @State private var month: MonthKey?   // nil means "this month", so it keeps following the calendar
    @State private var addingAccount = false
    @State private var selection: String?          // the chart slice (or the centre) being looked at
    @State private var dragX: CGFloat = 0
    @State private var slideEdge = Edge.trailing   // which side the next month's label slides in from

    var body: some View {
        WithLedger { ledger in
            let data = ledger.home(month: month)
            Group { if !data.hasData { emptyState } else { content(data, ledger) } }
                .toolbar { toolbar(data.hasData ? data : nil) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingAccount) { AccountEditSheet(account: nil) }
    }

    private var emptyState: some View {
        Screen {
            VStack(spacing: 14) {
                Mascot(name: "hero", height: 120)
                Text("Nothing tracked yet").font(.rounded(18, .bold))
                Text("Screenshot your YouTrip transactions and any receipts. The app pieces together your spending from that, and you only correct what matters.")
                    .font(.rounded(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                NavigationLink(value: Route.add) { Text("Add your first screenshots").font(.rounded(16, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .foregroundStyle(Theme.onAccent).background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                Button("Or look around with sample data") { DemoData.load(into: context); toaster.show("Sample data loaded") }
                    .font(.rounded(14, .semibold)).foregroundStyle(Theme.accent)
            }
            .card(padding: 28)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ data: HomeData?) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { NavigationLink(value: Route.search) { Image(systemName: "magnifyingglass") } }
        ToolbarItem(placement: .principal) {
            if data == nil { Text("Welcome").font(.rounded(17, .bold)) }
        }
        ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: Route.more) { Image(systemName: "gearshape") } }
    }

    private func content(_ data: HomeData, _ ledger: Ledger) -> some View {
        Screen {
            if let trip = ledger.activeTrip {
                NavigationLink(value: Route.tripMode) {
                    HStack { Glyph(symbol: Art.trip, size: 16); Text("Trip Mode is on · \(trip.name)").font(.rounded(14, .semibold)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                        .padding(12).background(Theme.greenBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain)
            }
            balancesStrip(ledger)
            VStack(spacing: 14) {
                monthCarousel(data)
                RadialChart(home: data, wedges: wedges(data), selection: $selection).frame(maxWidth: 480).frame(maxWidth: .infinity)
                    .offset(x: dragX * 0.35).opacity(1 - min(0.35, abs(dragX) / 500))
                if let selection { selectionLine(data, selection) } else { legend(data) }
                if data.usualMonths == 0 { firstMonthNote }
            }
            .animation(.snappy(duration: 0.25), value: selection)
            .onChange(of: data.month) { selection = nil }
            .contentShape(Rectangle())
            .simultaneousGesture(swipe(data))
            .sensoryFeedback(.selection, trigger: data.month)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 12) {
                thisMonthCard(data)
                paceCard(data)
                needsLookCard(data)
                comparedCard(data)
            }
        }
    }

    // MARK: swiping between months

    private func monthName(_ key: MonthKey) -> String {
        let thisYear = Dates.calendar.component(.year, from: Date())
        return key.year == thisYear ? key.firstDay.formatted(.dateTime.month(.wide)) : key.firstDay.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
    }

    /// "August  **September**  October": the months either side are tappable and the whole row slides when the month changes.
    private func monthCarousel(_ data: HomeData) -> some View {
        ZStack {
            HStack(spacing: 0) {
                Button { shift(data, by: -1) } label: {
                    Text(data.previous.map(monthName) ?? "").font(.rounded(14, .medium)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).disabled(data.previous == nil)
                Text(monthName(data.month)).font(.rounded(20, .heavy)).frame(maxWidth: .infinity)
                Button { shift(data, by: 1) } label: {
                    Text(data.next.map(monthName) ?? "").font(.rounded(14, .medium)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).disabled(data.next == nil)
            }
            .id(data.month)
            .transition(.asymmetric(insertion: .move(edge: slideEdge).combined(with: .opacity),
                                    removal: .move(edge: slideEdge == .trailing ? .leading : .trailing).combined(with: .opacity)))
        }
        .frame(height: 30).clipped()
    }

    /// delta -1 = earlier month, +1 = later. The slices morph into the new month's shape.
    private func shift(_ data: HomeData, by delta: Int) {
        guard let target = delta < 0 ? data.previous : data.next else { return }
        slideEdge = delta > 0 ? .trailing : .leading
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { month = target == MonthKey.current ? nil : target }
    }

    /// Drag the chart sideways: left to see the next month, right for the one before. It follows your finger a little, and gives up
    /// resistance at the first and last month.
    private func swipe(_ data: HomeData) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                let wantsEarlier = value.translation.width > 0
                let blocked = wantsEarlier ? data.previous == nil : data.next == nil
                dragX = value.translation.width * (blocked ? 0.25 : 1)
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.4
                let predicted = value.predictedEndTranslation.width
                if horizontal, abs(predicted) > 90 || abs(value.translation.width) > 50 { shift(data, by: predicted > 0 ? -1 : 1) }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { dragX = 0 }
            }
    }

    /// Where the money is: one chip per account, with what it holds (or "Set" until you've entered a balance).
    private func balancesStrip(_ ledger: Ledger) -> some View {
        let balances = ledger.accounts.map { ($0, ledger.currentBalance(for: $0.account)) }
        return VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(balances, id: \.0.id) { account, info in
                        NavigationLink(value: Route.account(account.account)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) { Glyph(symbol: account.icon, size: 20); Text(account.name).font(.rounded(12, .semibold)).foregroundStyle(Theme.muted).lineLimit(1) }
                                Text(info.map { Money.whole($0.implied) } ?? "Set").font(.rounded(17, .heavy)).foregroundStyle(info == nil ? Theme.accent : Theme.text)
                            }
                            .frame(minWidth: 96, alignment: .leading).padding(10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line) }
                        }.buttonStyle(.plain)
                        .reorderableAccount(account.account.rawValue)
                    }
                    Button { addingAccount = true } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 56)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                    }.buttonStyle(.plain).accessibilityLabel("Add an account")
                }
            }
        }
    }

    private func wedges(_ data: HomeData) -> [RadialChart.Wedge] {
        var list = data.categories.filter { $0.actual > 0 }.map { row in
            RadialChart.Wedge(id: row.id, name: row.category.name, icon: row.category.icon, color: Color(hex: row.category.effectiveColorHex),
                              actual: row.actual, usual: row.usual, budget: row.budget, muted: false,
                              route: .category(CategoryTarget(category: row.category, unsortedOf: nil, scope: .month(data.month))))
        }
        if data.unsorted > 0 {
            list.append(.init(id: "unsorted", name: "Unsorted", icon: nil, color: Color(hex: "e3d5b4"), actual: data.unsorted, usual: nil, budget: nil, muted: true,
                              route: .category(CategoryTarget(category: nil, unsortedOf: nil, scope: .month(data.month)))))
        }
        if data.untracked > 0 {
            list.append(.init(id: "untracked", name: "Untracked", icon: "?", color: Color(hex: "d9d6d0"), actual: data.untracked,
                              usual: nil, budget: nil, muted: false, route: .balance))
        }
        return list
    }

    private func legend(_ data: HomeData) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 12, height: 12); Text("Spent") }
            if data.usualMonths > 0 {
                HStack(spacing: 6) { Circle().strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 12, height: 12)
                    Text("Usual pace") }
            }
        }
        .font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
    }

    /// Shown only until there is a full earlier month to call "usual".
    private var firstMonthNote: some View {
        Text("First month with BroXc! After it, your usual spending appears as a ring around the chart.")
            .font(.rounded(11)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, 12)
    }

    /// What the tapped slice (or the centre) says: its budget progress, and a way into the category.
    @ViewBuilder
    private func selectionLine(_ data: HomeData, _ id: String) -> some View {
        let isTotal = id == RadialChart.totalID
        let wedge = wedges(data).first { $0.id == id }
        let spent = isTotal ? data.total : (wedge?.actual ?? 0)
        let budget = isTotal ? data.budgetTotal : wedge?.budget.flatMap { $0 > 0 ? $0 : nil }
        let name = isTotal ? "Total budget" : (wedge?.name ?? "")
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if let budget {
                    let share = spent / budget
                    Text("\(name) · \(Money.whole(spent)) of \(Money.whole(budget)) · \(Int((share * 100).rounded()))%")
                        .foregroundStyle(share > 1 ? Theme.bad : Theme.text)
                } else {
                    Text("\(name) · \(Money.whole(spent))").foregroundStyle(Theme.text)
                    if let usual = wedge?.usual { Text("Usual by now \(Money.whole(usual * paceScale(data)))").foregroundStyle(Theme.muted).font(.rounded(11)) }
                }
            }
            .font(.rounded(13, .bold)).lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let wedge, !isTotal {
                Button { navigation.open(wedge.route) } label: {
                    Text("Open").font(.rounded(12, .bold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(Theme.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
        .transition(.opacity)
    }

    /// The share of a usual month that has gone by (the chart judges slices against usual-by-now, so this line does too).
    private func paceScale(_ data: HomeData) -> Double {
        guard data.isCurrent, data.elapsedFraction < 1 else { return 1 }
        return max(data.elapsedFraction, 0.25)
    }

    // MARK: cards

    private func tile<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
    }

    private func miniStat(_ value: String, _ caption: String, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.rounded(16, .bold))
            Text(caption).font(.rounded(11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func thisMonthCard(_ data: HomeData) -> some View {
        tile {
            Text("This month").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
            Text(Money.whole(data.total)).font(.rounded(26, .heavy))
            Text("spent by you").font(.rounded(12)).foregroundStyle(Theme.muted)
            if let budget = data.totalBudget {
                ProgressView(value: min(data.total, budget), total: budget).tint(data.total > budget ? Theme.bad : Theme.good)
                Text(data.total > budget ? "\(Money.whole(data.total - budget)) over \(Money.whole(budget))" : "\(Money.whole(budget - data.total)) left of \(Money.whole(budget))")
                    .font(.rounded(11)).foregroundStyle(data.total > budget ? Theme.bad : Theme.muted)
            }
            NavigationLink(value: Route.balance) {
                miniStat(data.balance.map { Money.whole($0.implied) } ?? "Check", data.balance == nil ? "your balance" : "actual balance", background: Theme.blueBg)
            }.buttonStyle(.plain)
            OwedBackLink(owed: data.owedBack)
        }
    }

    private func paceScene(_ status: PaceStatus) -> String? {
        switch status { case .good: "mascot-scene-on-track"; case .watch: "mascot-scene-nearing-limit"; case .over: "mascot-scene-over-budget"; case .neutral: nil }
    }

    private func paceCard(_ data: HomeData) -> some View {
        tile {
            if let scene = paceScene(data.status) {
                Color.clear.frame(height: 70).overlay { Image(scene).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(data.isCurrent ? "At this pace" : "Month total").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
            Text(Money.whole(data.projected)).font(.rounded(26, .heavy))
            Text(data.isCurrent ? "projected spend" : "spent").font(.rounded(12)).foregroundStyle(Theme.muted)
            if data.paceActual.isEmpty && data.paceUsual.isEmpty { Text("Builds up as you add spending.").font(.rounded(12)).foregroundStyle(Theme.muted) }
            else { PaceChart(actual: data.paceActual, usual: data.paceUsual, projected: data.projected, days: data.daysInMonth,
                             today: data.elapsedDays, showProjection: data.elapsedFraction < 1) }
            if let left = data.balanceAfter { Text("≈ \(Money.whole(left)) left by month end").font(.rounded(11)).foregroundStyle(Theme.muted) }
        }
    }

    private func needsLookCard(_ data: HomeData) -> some View {
        NavigationLink(value: Route.review) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Needs a look").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
                if data.uncertain + data.confident == 0 && data.matchesToCheck == 0 {
                    Text("Nothing yet. Add a receipt or a YouTrip screenshot.").font(.rounded(12)).foregroundStyle(Theme.muted)
                } else {
                    Text(Money.whole(data.uncertain)).font(.rounded(26, .heavy))
                    Text("could use a look").font(.rounded(12)).foregroundStyle(Theme.muted)
                    Text("\(Money.whole(data.confident)) confidently understood").font(.rounded(12))
                    VStack(alignment: .leading, spacing: 2) {
                        if data.suggestions > 0 { Text("• \(data.suggestions) suggestion\(data.suggestions == 1 ? "" : "s")") }
                        if data.unknown > 0 { Text("• \(data.unknown) unknown") }
                        if data.matchesToCheck > 0 { Text("• \(data.matchesToCheck) match\(data.matchesToCheck == 1 ? "" : "es") to check") }
                    }.font(.rounded(12))
                    HStack(spacing: 2) { Text("Review"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                        .font(.rounded(13, .bold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).card(padding: 14, background: Theme.warmBg, bordered: false)
        }.buttonStyle(.plain)
    }

    private func comparedCard(_ data: HomeData) -> some View {
        tile {
            Text("Compared with usual").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
            if data.compared.isEmpty {
                Text(data.usualMonths > 0 ? "Right in line with usual." : "Needs a month or two of history to know what’s usual for you.")
                    .font(.rounded(12)).foregroundStyle(Theme.muted)
            } else {
                ForEach(data.compared) { row in
                    NavigationLink(value: Route.category(CategoryTarget(category: row.category, unsortedOf: nil, scope: .month(data.month)))) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: row.category.effectiveColorHex)).frame(width: 9, height: 9)
                            Text(row.category.name).font(.rounded(14)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(row.delta > 0 ? "+" : "−")\(Money.whole(abs(row.delta)))").font(.rounded(14, .bold))
                                .foregroundStyle(row.delta > 0 ? Theme.bad : Theme.good)
                        }
                    }.buttonStyle(.plain)
                }
            }
            NavigationLink(value: Route.trends) {
                HStack(spacing: 2) { Text("See more"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                    .font(.rounded(13, .bold)).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// "Owed back to you" shortcut: jumps to the Reimburse tab's content.
private struct OwedBackLink: View {
    let owed: Double
    @Environment(AppNavigation.self) private var navigation
    var body: some View {
        Button { navigation.selectedTab = .reimburse } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(Money.whole(owed)).font(.rounded(16, .bold))
                Text("owed back to you").font(.rounded(11)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
            .background(owed > 0 ? Theme.orangeBg : Theme.segBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain)
    }
}
