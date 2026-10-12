import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Search

struct SearchView: View {
    enum Scope: Hashable { case all, transactions, receipts, trips }
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var openItemID: String?

    var body: some View {
        WithLedger { ledger in
            let results = ledger.search(query)
            let itemTransactions = Set(results.items.compactMap { $0.transaction?.persistentModelID })
            let extra = results.transactions.filter { $0.transaction.map { !itemTransactions.contains($0.persistentModelID) } ?? true }
            Screen {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Try “salmon”, a shop name, a category, or a trip.").font(.rounded(14)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    SegmentedTabs(options: [(Scope.all, "All"), (Scope.transactions, "Transactions"), (Scope.receipts, "Receipts"), (Scope.trips, "Trips")], selection: $scope)
                    if (scope == .all || scope == .transactions) && (!results.items.isEmpty || !extra.isEmpty) {
                        SectionTitle("Transactions") { if !results.items.isEmpty { SelectButton(selecting: $selecting, selected: $selected) } }
                        if !results.items.isEmpty {
                            ItemList(items: Array(results.items.prefix(scope == .all ? 8 : 40)), selecting: $selecting, selected: $selected) { openItemID = $0.id }
                        }
                        if !extra.isEmpty {
                            Rows { ForEach(extra.prefix(scope == .all ? 5 : 40)) { e in
                                NavigationLink(value: Route.transaction(e.transaction!)) { TransactionRow(entry: e, showDate: true) }.buttonStyle(.plain)
                            } }.flushCard()
                        }
                    }
                    if (scope == .all || scope == .receipts) && !results.receipts.isEmpty {
                        SectionTitle("Receipts")
                        Rows { ForEach(Array(results.receipts.enumerated()), id: \.offset) { _, r in
                            NavigationLink(value: ledger.transactions.first(where: { $0.matchedReceipt?.persistentModelID == r.receipt.persistentModelID }).map(Route.transaction) ?? Route.receipt(r.receipt)) {
                                HStack(spacing: 12) {
                                    IconTile(symbol: Art.receipt, color: Theme.miscColor)
                                    VStack(alignment: .leading) { Text(r.receipt.merchant ?? "Receipt").font(.rounded(15, .semibold))
                                        Text("\(r.receipt.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "") · \(r.matched) item\(r.matched == 1 ? "" : "s") matched").font(.rounded(12)).foregroundStyle(Theme.muted) }
                                    Spacer()
                                }.padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                            }.buttonStyle(.plain)
                        } }.flushCard()
                    }
                    if (scope == .all || scope == .trips) && !results.trips.isEmpty {
                        SectionTitle("Trips")
                        Rows { ForEach(results.trips) { trip in
                            NavigationLink(value: Route.trip(trip)) {
                                HStack(spacing: 12) { TripCover(trip: trip, radius: 10).frame(width: 40, height: 40); VStack(alignment: .leading) { Text(trip.name).font(.rounded(15, .semibold)); Text(trip.dateRange).font(.rounded(12)).foregroundStyle(Theme.muted) }; Spacer() }
                                    .padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                            }.buttonStyle(.plain)
                        } }.flushCard()
                    }
                    if results.items.isEmpty && extra.isEmpty && results.receipts.isEmpty && results.trips.isEmpty {
                        Text("Nothing found for “\(query)”.").font(.rounded(14)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
            }
            .itemSelection(selecting: $selecting, selected: $selected, ledger: ledger, all: results.items)
            .sheet(isPresented: Binding(get: { openItemID != nil }, set: { if !$0 { openItemID = nil } })) { if let id = openItemID { ItemSheet(itemID: id) } }
        }
        .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Items, merchants, categories, trips")
    }
}

// MARK: - Trends

struct TrendsView: View {
    enum Range: String, CaseIterable { case m1 = "1M", m3 = "3M", m6 = "6M", y1 = "1Y", all = "All"
        var months: Int? { switch self { case .m1: 1; case .m3: 3; case .m6: 6; case .y1: 12; case .all: nil } } }
    @State private var range = Range.m1

    var body: some View {
        WithLedger { ledger in
            let d = ledger.trends(rangeMonths: range.months)
            let peak = max(1, d.changes.map { abs($0.delta ?? $0.actual) }.max() ?? 1)
            Screen {
                HStack { ForEach(Range.allCases, id: \.self) { r in
                    Button { range = r } label: {
                        Text(r.rawValue).font(.rounded(13, .semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                            .foregroundStyle(range == r ? Theme.onAccent : Theme.muted).background(range == r ? Theme.accent : Theme.surface, in: Capsule()).overlay { Capsule().stroke(Theme.line) }
                    }
                } }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        HStack(spacing: 5) { Circle().fill(Theme.accent).frame(width: 9, height: 9); Text(range == .m1 ? "This month" : "Monthly spending") }
                        if d.usualMonthly != nil { HStack(spacing: 5) { Circle().fill(Theme.mutedLine).frame(width: 9, height: 9); Text("Usual") } }
                    }.font(.rounded(12)).foregroundStyle(Theme.muted)
                    if range == .m1 { TrendChart(mode: .daily(actual: d.dailyActual, usual: d.dailyUsual, days: d.daysInMonth, today: d.todayDay)) }
                    else { TrendChart(mode: .monthly(d.months, usual: d.usualMonthly)) }
                    HStack {
                        stat(Money.whole(d.thisMonth), "this month"); stat(Money.string(d.averageDaily), "avg per day"); stat(d.usualMonthly.map(Money.whole) ?? "—", "usual month")
                    }
                }.card()

                SectionTitle("Spending by category")
                if d.changes.isEmpty { EmptyCard("No spending this month yet") }
                else {
                    Rows { ForEach(d.changes) { c in
                        NavigationLink(value: Route.category(CategoryTarget(category: c.category, unsortedOf: nil, scope: .month(.current)))) {
                            HStack(spacing: 12) {
                                IconTile(symbol: c.category.icon, color: Color(hex: c.category.effectiveColorHex), size: 34)
                                VStack(spacing: 6) {
                                    HStack { Text(c.category.name).font(.rounded(15, .semibold)); Spacer(); Text(Money.whole(c.actual)).font(.rounded(15, .bold)) }
                                    ProgressView(value: abs(c.delta ?? c.actual), total: peak).tint(c.delta == nil ? Color(hex: c.category.effectiveColorHex) : (c.delta! > 0 ? Theme.bad : Theme.good))
                                }
                                if let delta = c.delta { Text("\(delta > 0 ? "+" : "−")\(Money.whole(abs(delta)))").font(.rounded(14, .bold)).foregroundStyle(delta > 0 ? Theme.bad : Theme.good).frame(minWidth: 54, alignment: .trailing) }
                            }.padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
                        }.buttonStyle(.plain)
                    } }.flushCard()
                }
                SectionTitle("Which days you spend")
                VStack(alignment: .leading, spacing: 6) { WeekdayBars(points: d.weekdays) }.card()
                if !d.recurring.isEmpty {
                    SectionTitle("Looks recurring")
                    Rows { ForEach(d.recurring) { r in
                        HStack { VStack(alignment: .leading) { Text(r.name).font(.rounded(15, .semibold)); Text("\(r.months) months · \(r.count) times").font(.rounded(12)).foregroundStyle(Theme.muted) }
                            Spacer(); Text("~\(Money.whole(r.typical))").font(.rounded(15, .bold)) }.padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
                    } }.flushCard()
                }
                if !d.trips.isEmpty {
                    SectionTitle("Trips over time")
                    Rows { ForEach(d.trips) { t in
                        NavigationLink(value: Route.trip(t.trip)) {
                            HStack(spacing: 12) { TripCover(trip: t.trip, radius: 10).frame(width: 34, height: 34)
                                VStack(alignment: .leading) { Text(t.trip.name).font(.rounded(15, .semibold)); Text(t.trip.startDate?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "").font(.rounded(12)).foregroundStyle(Theme.muted) }
                                Spacer(); Text(Money.whole(t.spend)).font(.rounded(15, .bold)); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedLine)
                            }.padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
                        }.buttonStyle(.plain)
                    } }.flushCard()
                }
            }
        }
        .navigationTitle("Trends").navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 1) { Text(value).font(.rounded(17, .bold)); Text(caption).font(.rounded(11)).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity)
    }
}

// MARK: - Review (needs a look)

struct ReviewView: View {
    enum Scope { case month, all }
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var scope = Scope.month
    @State private var confirmAll = false
    @State private var moving: [String]?

    var body: some View {
        WithLedger { ledger in
            let month = MonthKey.current
            let d = ledger.review(month: scope == .month ? month : nil)
            let suggestions = d.items.filter { $0.confidence == .suggested }
            Screen {
                SegmentedTabs(options: [(Scope.month, month.firstDay.formatted(.dateTime.month(.wide))), (Scope.all, "All time")], selection: $scope)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Money.whole(d.uncertain)).font(.rounded(30, .heavy))
                    Text("could use a look").foregroundStyle(Theme.muted)
                    Text("\(Money.whole(d.confident)) is confidently understood. This is optional: your totals already include everything below.").font(.rounded(13))
                    if suggestions.count > 1 { Button("Confirm all \(suggestions.count) suggestions") { confirmAll = true }.buttonStyle(.borderedProminent) }
                }.frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.warmBg, bordered: false)
                if !d.matches.isEmpty {
                    SectionTitle("\(d.matches.count) match\(d.matches.count == 1 ? "" : "es") to check")
                    Rows { ForEach(d.matches) { t in
                        NavigationLink(value: Route.transaction(t)) {
                            HStack(spacing: 12) { IconTile(symbol: Art.link, color: Theme.warn)
                                VStack(alignment: .leading) { Text(t.transactionDescription ?? "Charge").font(.rounded(15, .semibold)); Text(t.matchNote ?? "Linked to a receipt, not certain").font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1) }
                                Spacer(); Text(Money.string(t.amountSGD)).font(.rounded(15, .bold)) }
                                .padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                        }.buttonStyle(.plain)
                    } }.flushCard()
                }
                if !d.items.isEmpty {
                    SectionTitle("Biggest first")
                    let groups = groupedByReceipt(d.items)
                    ForEach(groups.prefix(25)) { group in groupCard(group, ledger) }
                    if groups.count > 25 { Text("\(groups.count - 25) smaller ones not shown. They’re fine to leave.").font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity) }
                } else if d.matches.isEmpty { EmptyCard("All clear", "Nothing needs a look right now.", mascot: "expr-happy") }
            }
            .confirmationDialog("Confirm all \(suggestions.count) suggested categories? Only do this if the guesses look right to you.", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Confirm all") { Actions.acceptSuggestions(suggestions, ledger: ledger, in: context); toaster.show("Confirmed \(suggestions.count)") }
            }
            .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
                if let ids = moving {
                    let chosen = ledger.items.filter { ids.contains($0.id) }
                    CategoryPicker(title: chosen.count > 1 ? "Move all \(chosen.count) to…" : "Move to…", selected: chosen.count == 1 ? chosen[0].category : nil, teach: true) { category, remember, similar in
                        guard let category else { return }
                        Actions.assignCategory(chosen, to: category, alsoSimilar: similar, remember: remember, ledger: ledger, in: context)
                        toaster.show(recategorisedMessage(chosen.count, to: category.name))
                    }
                }
            }
        }
        .navigationTitle("Needs a look").navigationBarTitleDisplayMode(.inline)
    }

    /// Everything from one shop visit together, biggest visit first.
    private struct Group: Identifiable {
        let id: String
        let items: [ItemView]
        var total: Double { items.reduce(0) { $0 + ($1.personalSGD ?? 0) } }
    }

    private func groupedByReceipt(_ items: [ItemView]) -> [Group] {
        let keyed = Dictionary(grouping: items) { item in item.receipt.map { "r-\($0.persistentModelID.hashValue)" } ?? item.id }
        return keyed.map { Group(id: $0.key, items: $0.value.sorted { ($0.personalSGD ?? 0) > ($1.personalSGD ?? 0) }) }
            .sorted { $0.total > $1.total }
    }

    @ViewBuilder
    private func groupCard(_ group: Group, _ ledger: Ledger) -> some View {
        if group.items.count == 1, let only = group.items.first { card(only, ledger) }
        else {
            let first = group.items[0]
            let suggestions = group.items.filter { $0.confidence == .suggested }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.merchant ?? "Unknown store").font(.rounded(16, .bold))
                        Text("\(first.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "") · \(group.items.count) items").font(.rounded(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(); Text(Money.string(group.total)).font(.rounded(16, .bold))
                }
                HStack(spacing: 8) {
                    Button("Set all…") { moving = group.items.map(\.id) }.buttonStyle(.bordered).controlSize(.small)
                    if suggestions.count > 1 {
                        Button("Confirm \(suggestions.count) guesses") { Actions.acceptSuggestions(suggestions, ledger: ledger, in: context); toaster.show("Confirmed \(suggestions.count)") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(item.name).font(.rounded(14, .semibold)).lineLimit(2)
                                Spacer(); Text(Money.string(item.personalSGD)).font(.rounded(14, .bold))
                            }
                            HStack {
                                CategoryChip(category: item.category, confidence: item.confidence)
                                Spacer()
                                if item.confidence == .suggested { Button("Yes") { Actions.acceptSuggestions([item], ledger: ledger, in: context); toaster.show("Confirmed") }.buttonStyle(.borderedProminent).controlSize(.mini) }
                                Button(item.confidence == .suggested ? "Change" : "Choose") { moving = [item.id] }.buttonStyle(.bordered).controlSize(.mini)
                            }
                        }.padding(.vertical, 10).rowDivider()
                    }
                }
            }.card(padding: 14)
        }
    }

    private func card(_ item: ItemView, _ ledger: Ledger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.rounded(15, .semibold))
                    Text("\(item.merchant ?? "") · \(item.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "")").font(.rounded(12)).foregroundStyle(Theme.muted)
                }
                Spacer(); Text(Money.string(item.personalSGD)).font(.rounded(15, .bold))
            }
            HStack {
                CategoryChip(category: item.category, confidence: item.confidence, full: true)
                Spacer()
                if item.confidence == .suggested { Button("Yes") { Actions.acceptSuggestions([item], ledger: ledger, in: context); toaster.show("Confirmed") }.buttonStyle(.borderedProminent).controlSize(.small) }
                Button(item.confidence == .suggested ? "Change" : "Choose") { moving = [item.id] }.buttonStyle(.bordered).controlSize(.small)
            }
        }.card(padding: 14)
    }
}

// MARK: - Balance check

struct BalanceView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var account: Account
    @State private var amount = ""
    @State private var date = Date()

    init(account: Account = .dbs) { _account = State(initialValue: account) }

    var body: some View {
        WithLedger { ledger in
            let current = ledger.currentBalance(for: account)
            let tracked = ledger.transactions.contains { $0.account == account }
            Screen {
                if ledger.accounts.count <= 4 {
                    SegmentedTabs(options: ledger.accounts.map { ($0.account, $0.name) }, selection: $account)
                } else {
                    Picker("Account", selection: $account) { ForEach(ledger.accounts) { Text($0.name).tag($0.account) } }.pickerStyle(.menu)
                }
                NavigationLink(value: Route.accounts) { Text("Manage accounts").font(.rounded(13, .semibold)) }
                VStack(alignment: .leading, spacing: 6) {
                    if let current {
                        Text(tracked ? "Balance implied by your records" : "Balance you last entered").font(.rounded(12)).foregroundStyle(Theme.muted)
                        Text(Money.string(current.implied)).font(.rounded(30, .heavy))
                        Text("Last checked \(current.reconciledOn.formatted(.dateTime.day().month(.abbreviated).year())) at \(Money.string(current.reconciledAmount)), then moved by everything recorded since.")
                            .font(.rounded(12)).foregroundStyle(Theme.muted)
                    } else {
                        Text("Check your real \(ledger.info(account).name) balance now and then").font(.rounded(16, .bold))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).card()
                VStack(alignment: .leading, spacing: 12) {
                    Text("What does \(ledger.info(account).name) show right now?").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
                    HStack { Text("$").font(.rounded(20, .bold)); TextField(current.map { String(format: "%.2f", $0.implied) } ?? "0.00", text: $amount).keyboardType(.decimalPad).font(.rounded(20, .bold)) }
                        .padding(12).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    DatePicker("As of", selection: $date, in: ...Date(), displayedComponents: .date).font(.rounded(14))
                    PrimaryButton(title: "Save balance", disabled: Double(amount.replacingOccurrences(of: ",", with: ".")) == nil) {
                        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
                        let first = ledger.latestReconciliation(for: account) == nil
                        let result = Actions.reconcile(actual: value, on: date.startOfDay, account: account, ledger: ledger, in: context)
                        toaster.show(first ? "Saved as your starting point" : result.gap > 0.005 ? "\(Money.string(result.gap)) untracked" : result.gap < -0.005 ? "\(Money.string(-result.gap)) more than expected" : "Everything adds up")
                        amount = ""
                    }
                }.card()
                (Text("? Untracked ").bold() + Text("is money that left with no record at all: no merchant, no date, no category. The app won’t invent any. It shows as a grey ? on your spending map so the totals still add up."))
                    .font(.rounded(13)).card(background: Theme.blueBg, bordered: false)
                transfersSection(ledger)
                let history = ledger.reconciliations.filter { $0.account == account }.sorted { $0.createdAt > $1.createdAt }
                if !history.isEmpty {
                    SectionTitle("Past checks")
                    Rows { ForEach(history) { r in
                        HStack {
                            VStack(alignment: .leading) { Text(r.reconciledOn.formatted(.dateTime.day().month(.abbreviated).year())).font(.rounded(15, .semibold))
                                Text(r.impliedSGD.map { "expected \(Money.string($0))" } ?? "starting point").font(.rounded(12)).foregroundStyle(Theme.muted) }
                            Spacer()
                            VStack(alignment: .trailing) { Text(Money.string(r.actualSGD)).font(.rounded(15, .bold))
                                if r.untrackedSGD > 0.005 { Text("? \(Money.string(r.untrackedSGD)) untracked").font(.rounded(12)).foregroundStyle(Theme.bad) }
                                if r.untrackedSGD < -0.005 { Text("\(Money.string(-r.untrackedSGD)) extra").font(.rounded(12)).foregroundStyle(Theme.muted) } }
                        }.padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
                    } }.flushCard()
                }
            }
        }
        .navigationTitle("Balance check").navigationBarTitleDisplayMode(.inline)
    }
}

extension BalanceView {
    /// Transfers between your accounts that haven't found their other half: the usual reason a balance doesn't add up.
    @ViewBuilder
    fileprivate func transfersSection(_ ledger: Ledger) -> some View {
        let pairing = TransferPairing.pair(ledger.transactions, accounts: ledger.accounts)
        let mine = { (t: YouTripTransaction) in t.account == account }
        let waiting = pairing.waiting.filter(mine), missing = pairing.missing.filter(mine)
        let paired = ledger.transactions.filter { pairing.partner[$0.uid] != nil && $0.account == account }
        if !waiting.isEmpty || !missing.isEmpty || !paired.isEmpty {
            SectionTitle("Moves between your accounts")
            VStack(alignment: .leading, spacing: 8) {
                if !paired.isEmpty { Label("\(paired.count) matched on both sides", systemImage: "checkmark.circle.fill").font(.rounded(13)) }
                ForEach(waiting) { t in
                    NavigationLink(value: Route.transaction(t)) {
                        Text("⏳ \(Money.string(abs(t.amountSGD ?? 0))) \(t.isOutflow ? "out of" : "into") \(ledger.info(t.account).name) on \(t.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "?"): waiting for the other account").font(.rounded(13)).foregroundStyle(Theme.muted)
                    }.buttonStyle(.plain)
                }
                ForEach(missing) { t in
                    NavigationLink(value: Route.transaction(t)) {
                        Label("\(Money.string(abs(t.amountSGD ?? 0))) \(t.isOutflow ? "out of" : "into") \(ledger.info(t.account).name) on \(t.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "?"): no matching move in your other accounts", systemImage: "exclamationmark.triangle.fill").font(.rounded(13))
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }
}

// MARK: - Categories

struct CategoriesView: View {
    @Query(sort: \Category.sortOrder) private var all: [Category]
    @State private var editing: Category?
    @State private var creating = false

    var body: some View {
        let ordered = flatten(all.filter { $0.parent == nil }.sorted { $0.sortOrder < $1.sortOrder })
        Screen {
            Rows { ForEach(ordered, id: \.persistentModelID) { c in
                HStack(spacing: 10) {
                    IconTile(symbol: c.icon, color: Color(hex: c.effectiveColorHex), size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.name).font(.rounded(15))
                        if c.kind == .misc { Text("deliberate catch-all").font(.rounded(11)).foregroundStyle(Theme.muted) }
                        if c.kind == .grocery { Text("no-receipt groceries").font(.rounded(11)).foregroundStyle(Theme.muted) }
                        if let b = c.budgetSGD { Text("budget \(Money.whole(b)) / month").font(.rounded(11)).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    Button { editing = c } label: { Image(systemName: "pencil").foregroundStyle(Theme.muted).frame(width: 36, height: 36) }.buttonStyle(.plain)
                }.padding(.leading, 12 + CGFloat(c.depth) * 20).padding(.trailing, 8).padding(.vertical, 8).rowDivider()
            } }.flushCard()
        }
        .navigationTitle("Categories").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(item: $editing) { CategoryEditSheet(category: $0, parent: nil) }
        .sheet(isPresented: $creating) { CategoryEditSheet(category: nil, parent: nil) }
    }

    private func flatten(_ nodes: [Category]) -> [Category] {
        nodes.flatMap { [$0] + flatten($0.children.sorted { $0.sortOrder < $1.sortOrder }) }
    }
}

// MARK: - Add (screenshots)

struct AddView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @Environment(Toaster.self) private var toaster
    @Query private var trips: [Trip]
    @State private var youtripPick: PhotosPickerItem?
    @State private var photoPick: PhotosPickerItem?
    @State private var receiptPick: PhotosPickerItem?
    @State private var originalPick: PhotosPickerItem?
    @State private var scanning = false
    @State private var working: String?
    @State private var youtripResult: String?
    @State private var receiptResult: String?
    @State private var pendingTranslation: PendingTranslation?

    var body: some View {
        Screen {
            if let trip = trips.first(where: \.isActive) {
                Label("New items will join \(trip.name)", systemImage: "suitcase.fill").font(.rounded(14, .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Theme.greenBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            receiptCard
            VStack(alignment: .leading, spacing: 10) {
                Text("Transactions").font(.rounded(17, .bold))
                PhotosPicker(selection: $youtripPick, matching: .images) { pickerLabel("Choose screenshot", systemImage: "photo") }
                if working == "youtrip" { ProgressView("Reading the image…") }
                if let youtripResult { Text(youtripResult).font(.rounded(13)).foregroundStyle(Theme.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
            NavigationLink(value: Route.review) { Text("See what needs a look").font(.rounded(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.bordered)
        }
        .navigationTitle("Add").navigationBarTitleDisplayMode(.inline)
        .translationHost($pendingTranslation)
        .onChange(of: youtripPick) { _, item in if let item { Task { await readCharges(item) } } }
        .onChange(of: photoPick) { _, item in if let item { Task { await readPhoto(item) } } }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner(onScan: { image in scanning = false; if let data = image.pngData() { Task { await addReceiptPhoto(data) } } },
                            onCancel: { scanning = false }).ignoresSafeArea()
        }
    }

    private var receiptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receipt").font(.rounded(17, .bold))
            Text("Photograph the receipt as it is. It’s read in Swedish and the item names are translated to English on this phone. Nothing is sent anywhere.")
                .font(.rounded(13)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                if DocumentScanner.isSupported {
                    Button { scanning = true } label: { pickerLabel("Scan", systemImage: "camera.viewfinder") }.disabled(working != nil)
                }
                PhotosPicker(selection: $photoPick, matching: .images) { pickerLabel("Choose photo", systemImage: "photo") }.disabled(working != nil)
            }
            if working == "receipt" { ProgressView("Reading the receipt…") }
            if working == "translating" { ProgressView("Translating item names…") }
            if let receiptResult { Text(receiptResult).font(.rounded(13)).foregroundStyle(Theme.muted) }
            DisclosureGroup("Already have a Google Translate screenshot?") {
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $receiptPick, matching: .images) { pickerLabel(receiptPick == nil ? "Translated screenshot" : "Translated screenshot added", systemImage: "doc.text.image") }
                    PhotosPicker(selection: $originalPick, matching: .images) { pickerLabel(originalPick == nil ? "Original photo (optional)" : "Original photo added", systemImage: "camera") }
                    PrimaryButton(title: "Read translated screenshot", disabled: receiptPick == nil || working != nil) { Task { await readTranslatedScreenshot() } }
                }.padding(.top, 8)
            }
            .font(.rounded(14, .semibold)).tint(Theme.accent)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func pickerLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage).font(.rounded(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
            .foregroundStyle(Theme.accent).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func readCharges(_ item: PhotosPickerItem) async {
        working = "youtrip"; youtripResult = nil
        defer { working = nil; youtripPick = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = ImageLoader.cgImage(from: data) else { throw AppError("That image couldn’t be opened.") }
            let read = try await ReceiptReader.readTransactions(image)
            // which of your accounts this is: DBS shows the account name and number above the list
            let account = Actions.resolveAccount(kind: read.kind, hint: read.hint, in: context)
            let parsed = read.transactions.map { row -> ParsedTransaction in var r = row; r.account = account; return r }
            if parsed.isEmpty { throw AppError("No transactions found. Make sure the screenshot shows the transaction list.") }
            let saved = Actions.saveNew(Actions.settleTransfers(parsed, in: context), in: context)
            Actions.relinkTransfers(in: context)
            let matches = Matcher.run(in: context)
            let from = Actions.accountName(parsed.first?.account ?? .youtrip, in: context)
            youtripResult = "\(from): found \(parsed.count) transaction\(parsed.count == 1 ? "" : "s"), \(saved.added) new, \(saved.skipped) already saved\(Actions.lastRepairCount > 0 ? " (\(Actions.lastRepairCount) corrected)" : ""). \(matches.count) receipt\(matches.count == 1 ? "" : "s") linked."
        } catch { toaster.show(error.localizedDescription, error: true) }
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        defer { photoPick = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw AppError("That image couldn’t be opened.") }
            await addReceiptPhoto(data)
        } catch { toaster.show(error.localizedDescription, error: true) }
    }

    /// One photo of the original receipt: read it, translate the item names, save, and try to link it to its charge.
    private func addReceiptPhoto(_ data: Data) async {
        working = "receipt"; receiptResult = nil
        defer { working = nil }
        do {
            guard let image = ImageLoader.cgImage(from: data) else { throw AppError("That image couldn’t be opened.") }
            var draft = try await ReceiptReader.readOriginalPhoto(image, sourceImagePath: ImageLoader.store(data))
            if draft.items.isEmpty && draft.total == nil { throw AppError("Couldn’t read anything from that image. Try a clearer photo, or use Scan.") }
            working = "translating"
            let outcome = await translateOnDevice(ReceiptTranslation.texts(draft), via: $pendingTranslation)
            draft = ReceiptTranslation.apply(outcome.texts, to: draft)
            let receipt = Actions.save(draft, in: context)
            let matched = Matcher.run(in: context).first { $0.receipt === receipt }
            if outcome.texts == nil {
                // stay here: the reason it couldn't translate is worth reading
                receiptResult = summary(draft, matched: matched) + " Couldn’t translate, so item names are shown as printed. Reason: \(outcome.problem ?? "unknown")"
            } else { finishAdding(draft, matched: matched) }
        } catch { toaster.show(error.localizedDescription, error: true) }
    }

    private func readTranslatedScreenshot() async {
        guard let pick = receiptPick else { return }
        working = "receipt"; receiptResult = nil
        defer { working = nil; receiptPick = nil; originalPick = nil }
        do {
            guard let data = try await pick.loadTransferable(type: Data.self), let image = ImageLoader.cgImage(from: data) else { throw AppError("That image couldn’t be opened.") }
            var original: CGImage?
            if let o = originalPick, let d = try await o.loadTransferable(type: Data.self) { original = ImageLoader.cgImage(from: d) }
            let draft = try await ReceiptReader.readReceipt(translated: image, original: original, sourceImagePath: ImageLoader.store(data))
            if draft.items.isEmpty && draft.total == nil { throw AppError("Couldn’t read anything from that image. Try a clearer screenshot.") }
            let receipt = Actions.save(draft, in: context)
            finishAdding(draft, matched: Matcher.run(in: context).first { $0.receipt === receipt })
        } catch { toaster.show(error.localizedDescription, error: true) }
    }

    /// A receipt is in: go to Activity (where it now is) instead of leaving you on this page.
    private func finishAdding(_ draft: ReceiptDraft, matched: Matcher.Result?) {
        toaster.show("Added \(draft.merchant ?? "receipt"): \(draft.items.count) item\(draft.items.count == 1 ? "" : "s")" + (matched != nil ? ", linked" : ", no charge yet")
                     + (draft.repairs.isEmpty ? "" : " · fixed \(draft.repairs.count) unclear price\(draft.repairs.count == 1 ? "" : "s") from the total"))
        dismiss()
        navigation.selectedTab = .activity
    }

    private func summary(_ draft: ReceiptDraft, matched: Matcher.Result?) -> String {
        "Read “\(draft.merchant ?? "unknown store")”: \(draft.items.count) item\(draft.items.count == 1 ? "" : "s"), total \(draft.currency ?? "") \(draft.total.map { String(format: "%.2f", $0) } ?? "?"). "
            + (matched != nil ? "Linked to a YouTrip charge\(matched!.needsReview ? " (worth a look)" : "")." : "No matching YouTrip charge yet.")
    }
}

// MARK: - More

struct MoreView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmErase = false
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var pendingImport: Data?

    var body: some View {
        Screen {
            Rows {
                link(.help, Art.help, "Help", "Where to find things and how they work")
                link(.categories, Art.categories, "Categories", "Rename, reorder and colour")
                link(.budgets, Art.budget, "Budgets", "A total budget and one for each category")
            }.flushCard()
            Rows {
                HStack {
                    Text("Appearance").font(.rounded(15))
                    Spacer()
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }.flushCard()
            Rows {
                Button { exportData() } label: { MenuRow("Export my data", hint: "Save a backup file, photos included", chevron: false) }.buttonStyle(.plain)
                Button { importing = true } label: { MenuRow("Import a backup", hint: "Replace what’s on this phone with a backup file", chevron: false) }.buttonStyle(.plain)
            }.flushCard()
            Rows {
                if DemoData.isLoaded(in: context) {
                    Button { DemoData.remove(from: context); toaster.show("Sample data removed") } label: { MenuRow("Remove sample data", hint: "Takes out only the made-up spending, nothing of yours", chevron: false) }.buttonStyle(.plain)
                } else {
                    Button { DemoData.load(into: context); toaster.show("Sample data loaded") } label: { MenuRow("Load sample data", hint: "Adds made-up spending so you can explore. You can remove it again", chevron: false) }.buttonStyle(.plain)
                }
                Button { confirmErase = true } label: { MenuRow("Erase all data", hint: "Removes everything you’ve tracked on this phone", chevron: false).foregroundStyle(Theme.bad) }.buttonStyle(.plain)
            }.flushCard()
        }
        .navigationTitle("More").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Erase everything you’ve tracked on this phone? This can’t be undone.", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { Actions.eraseEverything(in: context); toaster.show("All data erased") }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareSheet(items: [shareURL]) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { pendingImport = data } else { toaster.show("That file couldn’t be opened.", error: true) }
        }
        .confirmationDialog("Replace everything on this phone with this backup? What’s here now will be gone.", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Replace with backup", role: .destructive) {
                guard let data = pendingImport else { return }
                do { try DataExport.restore(data, into: context); toaster.show("Backup restored") } catch { toaster.show(error.localizedDescription, error: true) }
                pendingImport = nil
            }
        }
    }

    private func exportData() {
        do { shareURL = try DataExport.makeBackupFile(from: context) } catch { toaster.show("Couldn’t make the backup: \(error.localizedDescription)", error: true) }
    }

    private func link(_ route: Route, _ emoji: String, _ title: String, _ hint: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) { IconTile(symbol: emoji, color: Theme.miscColor, size: 36)
                VStack(alignment: .leading, spacing: 1) { Text(title).font(.rounded(15)); Text(hint).font(.rounded(12)).foregroundStyle(Theme.muted) }
                Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mutedLine)
            }.padding(.horizontal, 16).padding(.vertical, 10).rowDivider()
        }.buttonStyle(.plain)
    }
}

// MARK: - Accounts

/// Your accounts: add a second DBS account, a fixed deposit, and so on. Screenshots are matched to an account by the
/// number DBS prints in the header, so each account's history lands on the right balance.
struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var adding = false
    @State private var editing: BankAccount?
    @Query(sort: \BankAccount.sortOrder) private var accounts: [BankAccount]

    var body: some View {
        WithLedger { ledger in
            Screen {
                Text("Money moving between your own accounts is never spending. Each account keeps its own balance, so a transfer from your fixed deposit shows up on both sides.")
                    .font(.rounded(13)).foregroundStyle(Theme.muted)
                Rows {
                    ForEach(accounts) { account in
                        Button { editing = account } label: {
                            HStack(spacing: 12) {
                                Glyph(symbol: account.kind.icon, size: 26).frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.name).font(.rounded(15, .semibold)).foregroundStyle(Theme.text)
                                    Text([account.kind.label, account.number].compactMap { $0 }.joined(separator: " · ")).font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer()
                                Text(ledger.currentBalance(for: Account(rawValue: account.key)).map { Money.whole($0.implied) } ?? "no balance").font(.rounded(14, .bold)).foregroundStyle(Theme.text)
                            }.padding(.horizontal, 14).padding(.vertical, 10).rowDivider()
                        }.buttonStyle(.plain)
                        .reorderableAccount(account.key)
                    }
                }.flushCard()
                PrimaryButton(title: "Add an account") { adding = true }
            }
        }
        .navigationTitle("Accounts").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { AccountEditSheet(account: nil) }
        .sheet(item: $editing) { AccountEditSheet(account: $0) }
    }
}

struct AccountEditSheet: View {
    let account: BankAccount?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var name = ""
    @State private var kind = AccountKind.bank
    @State private var number = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. DBS fixed deposit", text: $name) }
                Section("Kind") { Picker("Kind", selection: $kind) { ForEach(AccountKind.allCases) { Text($0.label).tag($0) } } }
                Section {
                    TextField("e.g. 123-45678-9", text: $number)
                } header: { Text("Account number (optional)") } footer: { Text("DBS prints it under the account name. With it, a screenshot of this account is recognised and filed here automatically.") }
                if let account {
                    Section { Button("Delete this account", role: .destructive) { confirmDelete = true } }
                        .confirmationDialog("Delete “\(account.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                do { try Actions.deleteAccount(account, in: context); dismiss() } catch { toaster.show(error.localizedDescription, error: true) }
                            }
                        }
                }
            }
            .navigationTitle(account == nil ? "New account" : "Edit account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        do {
                            if let account {
                                account.name = name.trimmingCharacters(in: .whitespaces); account.kind = kind
                                account.number = number.trimmingCharacters(in: .whitespaces).nilIfEmpty
                                try? context.save()
                                Actions.relinkTransfers(in: context)
                            } else { try Actions.addAccount(name: name, kind: kind, number: number, in: context); Actions.relinkTransfers(in: context) }
                            dismiss()
                        } catch { toaster.show(error.localizedDescription, error: true) }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if let account { name = account.name; kind = account.kind; number = account.number ?? "" } }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Budgets

/// One place for every budget: a total for the month, and one per category. With a total set the Home pace ring is judged against it;
/// without one, the category budgets added up, and without those, your usual month.
struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("totalBudget") private var totalBudget = 0.0
    @State private var totalText = ""
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    private var ordered: [Category] {
        func walk(_ parent: Category?) -> [Category] {
            categories.filter { $0.parent?.persistentModelID == parent?.persistentModelID && $0.kind != .deposit }
                .sorted { $0.sortOrder < $1.sortOrder }.flatMap { [$0] + walk($0) }
        }
        return walk(nil)
    }

    var body: some View {
        Screen {
            VStack(alignment: .leading, spacing: 8) {
                Text("Total monthly budget").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
                HStack {
                    Text("$").font(.rounded(26, .heavy))
                    TextField("No total budget", text: $totalText).keyboardType(.decimalPad).font(.rounded(26, .heavy))
                        .onChange(of: totalText) { _, new in totalBudget = Double(new.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
            SectionTitle("By category")
            Rows {
                ForEach(ordered) { category in
                    BudgetRow(category: category)
                }
            }.flushCard()
        }
        .navigationTitle("Budgets").navigationBarTitleDisplayMode(.inline)
        .onAppear { totalText = totalBudget > 0 ? totalBudget.formatted(.number.grouping(.never)) : "" }
    }
}

private struct BudgetRow: View {
    let category: Category
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: category.icon, color: Color(hex: category.effectiveColorHex), size: 30)
            Text(category.name).font(.rounded(15)).lineLimit(1)
            Spacer()
            Text("$").foregroundStyle(Theme.muted)
            TextField("none", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80).font(.rounded(15, .semibold))
                .onChange(of: text) { _, new in
                    guard loaded else { return }
                    category.budgetSGD = Double(new.replacingOccurrences(of: ",", with: "."))
                    try? context.save()
                }
        }
        .padding(.leading, CGFloat(category.depth) * 18 + 14).padding(.trailing, 14).padding(.vertical, 8).rowDivider()
        .onAppear { text = category.budgetSGD.map { $0.formatted(.number.grouping(.never)) } ?? ""; loaded = true }
    }
}
