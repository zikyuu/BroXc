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
                        SectionTitle("Transactions")
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
                                    IconTile(symbol: "🧾", color: Theme.miscColor)
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
                                HStack(spacing: 12) { IconTile(symbol: trip.emoji ?? "🧳", color: trip.tint); VStack(alignment: .leading) { Text(trip.name).font(.rounded(15, .semibold)); Text(trip.dateRange).font(.rounded(12)).foregroundStyle(Theme.muted) }; Spacer() }
                                    .padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                            }.buttonStyle(.plain)
                        } }.flushCard()
                    }
                    if results.items.isEmpty && extra.isEmpty && results.receipts.isEmpty && results.trips.isEmpty {
                        Text("Nothing found for “\(query)”.").font(.rounded(14)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
            }
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
                            .foregroundStyle(range == r ? .white : Theme.muted).background(range == r ? Theme.accent : Theme.surface, in: Capsule()).overlay { Capsule().stroke(Theme.line) }
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
                    if d.usualMonthly != nil { Text("Changes are against your usual, scaled to how much of the month has passed.").font(.rounded(12)).foregroundStyle(Theme.muted) }
                }
                SectionTitle("Which days you spend")
                VStack(alignment: .leading, spacing: 6) { WeekdayBars(points: d.weekdays); Text("Average per day, over the chosen range.").font(.rounded(12)).foregroundStyle(Theme.muted) }.card()
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
                            HStack(spacing: 12) { IconTile(symbol: t.trip.emoji ?? "🧳", color: t.trip.tint, size: 34)
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
    @State private var moving: String?

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
                            HStack(spacing: 12) { IconTile(symbol: "🔗", color: Theme.warn)
                                VStack(alignment: .leading) { Text(t.transactionDescription ?? "Charge").font(.rounded(15, .semibold)); Text(t.matchNote ?? "Linked to a receipt, not certain").font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1) }
                                Spacer(); Text(Money.string(t.amountSGD)).font(.rounded(15, .bold)) }
                                .padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                        }.buttonStyle(.plain)
                    } }.flushCard()
                }
                if !d.items.isEmpty {
                    SectionTitle("Biggest first")
                    ForEach(d.items.prefix(40)) { item in card(item, ledger) }
                    if d.items.count > 40 { Text("\(d.items.count - 40) smaller ones not shown. They’re fine to leave.").font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity) }
                } else if d.matches.isEmpty { EmptyCard("All clear", "Nothing needs a look right now.") }
            }
            .confirmationDialog("Confirm all \(suggestions.count) suggested categories? Only do this if the guesses look right to you.", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Confirm all") { Actions.acceptSuggestions(suggestions, ledger: ledger, in: context); toaster.show("Confirmed \(suggestions.count)") }
            }
            .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
                if let id = moving, let item = ledger.items.first(where: { $0.id == id }) {
                    CategoryPicker(title: "Move to…", selected: item.category, teach: true) { category, remember, similar in
                        guard let category else { return }
                        Actions.assignCategory([item], to: category, alsoSimilar: similar, remember: remember, ledger: ledger, in: context)
                        toaster.show("Moved to \(category.name)")
                    }
                }
            }
        }
        .navigationTitle("Needs a look").navigationBarTitleDisplayMode(.inline)
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
                Button(item.confidence == .suggested ? "Change" : "Choose") { moving = item.id }.buttonStyle(.bordered).controlSize(.small)
            }
        }.card(padding: 14)
    }
}

// MARK: - Balance check

struct BalanceView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var amount = ""
    @State private var date = Date()

    var body: some View {
        WithLedger { ledger in
            let current = ledger.currentBalance
            Screen {
                VStack(alignment: .leading, spacing: 6) {
                    if let current {
                        Text("Balance implied by your records").font(.rounded(12)).foregroundStyle(Theme.muted)
                        Text(Money.string(current.implied)).font(.rounded(30, .heavy))
                        Text("Last checked \(current.reconciledOn.formatted(.dateTime.day().month(.abbreviated).year())) at \(Money.string(current.reconciledAmount)), then moved by everything recorded since.")
                            .font(.rounded(12)).foregroundStyle(Theme.muted)
                    } else {
                        Text("Check your real balance now and then").font(.rounded(16, .bold))
                        Text("Enter what your card actually shows. The first check is a starting point; later ones reveal money the records can’t explain.").font(.rounded(13)).foregroundStyle(Theme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).card()
                VStack(alignment: .leading, spacing: 12) {
                    Text("What does your card show right now?").font(.rounded(13, .semibold)).foregroundStyle(Theme.muted)
                    HStack { Text("$").font(.rounded(20, .bold)); TextField(current.map { String(format: "%.2f", $0.implied) } ?? "0.00", text: $amount).keyboardType(.decimalPad).font(.rounded(20, .bold)) }
                        .padding(12).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    DatePicker("As of", selection: $date, in: ...Date(), displayedComponents: .date).font(.rounded(14))
                    PrimaryButton(title: "Save balance", disabled: Double(amount.replacingOccurrences(of: ",", with: ".")) == nil) {
                        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
                        let first = ledger.latestReconciliation == nil
                        let result = Actions.reconcile(actual: value, on: date.startOfDay, ledger: ledger, in: context)
                        toaster.show(first ? "Saved as your starting point" : result.gap > 0.005 ? "\(Money.string(result.gap)) untracked" : result.gap < -0.005 ? "\(Money.string(-result.gap)) more than expected" : "Everything adds up")
                        amount = ""
                    }
                }.card()
                (Text("? Untracked ").bold() + Text("is money that left with no record at all: no merchant, no date, no category. The app won’t invent any. It shows as a grey ? on your spending map so the totals still add up."))
                    .font(.rounded(13)).card(background: Theme.blueBg, bordered: false)
                let history = ledger.reconciliations.sorted { $0.createdAt > $1.createdAt }
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

// MARK: - Categories

struct CategoriesView: View {
    @Query(sort: \Category.sortOrder) private var all: [Category]
    @State private var editing: Category?
    @State private var creating = false

    var body: some View {
        let ordered = flatten(all.filter { $0.parent == nil }.sorted { $0.sortOrder < $1.sortOrder })
        Screen {
            Text("Organise spending your way. Categories nest as deep as you like. A budget sets the green line on your spending map.").font(.rounded(13)).foregroundStyle(Theme.muted)
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
    @Environment(Toaster.self) private var toaster
    @Query private var trips: [Trip]
    @State private var youtripPick: PhotosPickerItem?
    @State private var receiptPick: PhotosPickerItem?
    @State private var originalPick: PhotosPickerItem?
    @State private var working: String?
    @State private var youtripResult: String?
    @State private var receiptResult: String?

    var body: some View {
        Screen {
            if let trip = trips.first(where: \.isActive) {
                Text("🧳  New items will join \(trip.name)").font(.rounded(14, .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Theme.greenBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("YouTrip charges").font(.rounded(17, .bold))
                Text("Screenshot your YouTrip transaction list. Overlapping screenshots are fine: charges you’ve already saved are skipped.").font(.rounded(13)).foregroundStyle(Theme.muted)
                PhotosPicker(selection: $youtripPick, matching: .images) { pickerLabel("Choose screenshot", systemImage: "photo") }
                if working == "youtrip" { ProgressView("Reading the image…") }
                if let youtripResult { Text(youtripResult).font(.rounded(13)).foregroundStyle(Theme.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
            VStack(alignment: .leading, spacing: 10) {
                Text("Receipt").font(.rounded(17, .bold))
                Text("A Google Translate screenshot of the receipt (Swedish to English). Add the original photo too if you can: its store name helps match the charge.").font(.rounded(13)).foregroundStyle(Theme.muted)
                PhotosPicker(selection: $receiptPick, matching: .images) { pickerLabel(receiptPick == nil ? "Translated screenshot" : "Translated screenshot ✓", systemImage: "doc.text.image") }
                PhotosPicker(selection: $originalPick, matching: .images) { pickerLabel(originalPick == nil ? "Original photo (optional)" : "Original photo ✓", systemImage: "camera") }
                PrimaryButton(title: "Read receipt", disabled: receiptPick == nil || working != nil) { Task { await readReceipt() } }
                if working == "receipt" { ProgressView("Reading the image…") }
                if let receiptResult { Text(receiptResult).font(.rounded(13)).foregroundStyle(Theme.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
            NavigationLink(value: Route.review) { Text("See what needs a look").font(.rounded(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.bordered)
        }
        .navigationTitle("Add").navigationBarTitleDisplayMode(.inline)
        .onChange(of: youtripPick) { _, item in if let item { Task { await readCharges(item) } } }
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
            let parsed = try await ReceiptReader.readTransactions(image)
            if parsed.isEmpty { throw AppError("No charges found. Make sure the screenshot shows the transaction list.") }
            let saved = Actions.saveNew(parsed, in: context)
            let matches = Matcher.run(in: context)
            youtripResult = "Found \(parsed.count) charge\(parsed.count == 1 ? "" : "s"): \(saved.added) new, \(saved.skipped) already saved. \(matches.count) receipt\(matches.count == 1 ? "" : "s") linked."
        } catch { toaster.show(error.localizedDescription, error: true) }
    }

    private func readReceipt() async {
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
            let matched = Matcher.run(in: context).first { $0.receipt === receipt }
            receiptResult = "Read “\(draft.merchant ?? "unknown store")”: \(draft.items.count) item\(draft.items.count == 1 ? "" : "s"), total \(draft.currency ?? "") \(draft.total.map { String(format: "%.2f", $0) } ?? "?"). "
                + (matched != nil ? "Linked to a YouTrip charge\(matched!.needsReview ? " (worth a look)" : "")." : "No matching YouTrip charge yet.")
        } catch { toaster.show(error.localizedDescription, error: true) }
    }
}

// MARK: - More

struct MoreView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var confirmErase = false

    var body: some View {
        Screen {
            Rows {
                link(.add, "📥", "Add screenshots", "YouTrip charges and receipts")
                link(.review, "👀", "Needs a look", "Optional: confirm the app’s guesses")
                link(.search, "🔎", "Search", "Items, merchants, categories, trips")
            }.flushCard()
            Rows {
                link(.trends, "📈", "Trends", "Monthly patterns, usual vs now")
                link(.balance, "⚖️", "Balance check", "Find money the records can’t explain")
                link(.categories, "🗂️", "Categories", "Your own hierarchy and budgets")
            }.flushCard()
            Rows {
                Button { DemoData.load(into: context); toaster.show("Sample data loaded") } label: { MenuRow("Load sample data", hint: "Adds made-up spending so you can explore", chevron: false) }.buttonStyle(.plain)
                Button { confirmErase = true } label: { MenuRow("Erase all data", hint: "Removes everything you’ve tracked on this phone", chevron: false).foregroundStyle(Theme.bad) }.buttonStyle(.plain)
            }.flushCard()
            Text("Everything stays on this phone. No account, no cloud, no tracking.").font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
        }
        .navigationTitle("More").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Erase everything you’ve tracked on this phone? This can’t be undone.", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { Actions.eraseEverything(in: context); toaster.show("All data erased") }
        }
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
