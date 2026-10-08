import SwiftUI
import SwiftData

/// Home: the radial spending map, then the context cards (This Month, At This Pace, Needs a Look,
/// Compared With Usual) and recent activity.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @Environment(AppNavigation.self) private var navigation
    @State private var month: MonthKey?   // nil means "this month", so it keeps following the calendar

    var body: some View {
        WithLedger { ledger in
            let data = ledger.home(month: month)
            Group { if !data.hasData { emptyState } else { content(data, ledger) } }
                .toolbar { toolbar(data.hasData ? data : nil) }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        Screen {
            VStack(spacing: 14) {
                Text("🌱").font(.system(size: 44))
                Text("Nothing tracked yet").font(.rounded(18, .bold))
                Text("Screenshot your YouTrip transactions and any receipts. The app pieces together your spending from that, and you only correct what matters.")
                    .font(.rounded(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                NavigationLink(value: Route.add) { Text("Add your first screenshots").font(.rounded(16, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .foregroundStyle(.white).background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
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
            if let data {
                HStack(spacing: 6) {
                    Button { if let p = data.previous { month = p } } label: { Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 36) }.disabled(data.previous == nil)
                    Text(data.month.label).font(.rounded(17, .bold))
                    Button { if let n = data.next { month = n == MonthKey.current ? nil : n } } label: { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 36) }.disabled(data.next == nil)
                }
            } else { Text("Welcome").font(.rounded(17, .bold)) }
        }
        ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: Route.more) { Image(systemName: "gearshape") } }
    }

    private func content(_ data: HomeData, _ ledger: Ledger) -> some View {
        Screen {
            if let trip = ledger.activeTrip {
                NavigationLink(value: Route.tripMode) {
                    HStack { Text("🧳"); Text("Trip Mode is on · \(trip.name)").font(.rounded(14, .semibold)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                        .padding(12).background(Theme.greenBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain)
            }
            RadialChart(home: data, wedges: wedges(data)).frame(maxWidth: 420).frame(maxWidth: .infinity)
            legend
            if data.untracked > 0 {
                Text("Includes \(Money.whole(data.untracked)) of untracked money: the balance shows it left, but there’s no record of where.")
                    .font(.rounded(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 12) {
                thisMonthCard(data)
                paceCard(data)
                needsLookCard(data)
                comparedCard(data)
            }
            SectionTitle("Recent transactions") {
                Button("See all") { navigation.selectedTab = .activity }.font(.rounded(13, .semibold)).foregroundStyle(Theme.accent)
            }
            if data.recent.isEmpty { Text("Nothing yet.").font(.rounded(13)).foregroundStyle(Theme.muted) }
            else {
                Rows {
                    ForEach(data.recent) { entry in
                        NavigationLink(value: entry.transaction != nil ? Route.transaction(entry.transaction!) : Route.receipt(entry.receipt!)) {
                            TransactionRow(entry: entry, showDate: true)
                        }.buttonStyle(.plain)
                    }
                }.flushCard()
            }
        }
    }

    private func wedges(_ data: HomeData) -> [RadialChart.Wedge] {
        var list = data.categories.filter { $0.actual > 0 }.map { row in
            RadialChart.Wedge(id: row.id, name: row.category.name, icon: row.category.icon, color: Color(hex: row.category.effectiveColorHex),
                              actual: row.actual, reference: row.reference, referenceIsBudget: row.referenceIsBudget, usual: row.usual, muted: false,
                              route: .category(CategoryTarget(category: row.category, unsortedOf: nil, scope: .month(data.month))))
        }
        if data.unsorted > 0 {
            list.append(.init(id: "unsorted", name: "Unsorted", icon: nil, color: Color(hex: "e3d5b4"), actual: data.unsorted, reference: nil,
                              referenceIsBudget: false, usual: nil, muted: true,
                              route: .category(CategoryTarget(category: nil, unsortedOf: nil, scope: .month(data.month)))))
        }
        if data.untracked > 0 {
            list.append(.init(id: "untracked", name: "Untracked", icon: "?", color: Color(hex: "d9d6d0"), actual: data.untracked, reference: nil,
                              referenceIsBudget: false, usual: nil, muted: false, route: .balance))
        }
        return list
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 12, height: 12); Text("Actual") }
            HStack(spacing: 6) { Circle().strokeBorder(Color(hex: "8fe3a9"), lineWidth: 2).frame(width: 12, height: 12); Text("Budget (target)") }
            HStack(spacing: 6) { Capsule().fill(Color(hex: "3d7bff")).frame(width: 12, height: 4); Text("Usual (average)") }
        }
        .font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
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
            NavigationLink(value: Route.balance) {
                miniStat(data.balance.map { Money.whole($0.implied) } ?? "Check", data.balance == nil ? "your balance" : "actual balance", background: Theme.blueBg)
            }.buttonStyle(.plain)
            OwedBackLink(owed: data.owedBack)
        }
    }

    private func paceCard(_ data: HomeData) -> some View {
        tile {
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
