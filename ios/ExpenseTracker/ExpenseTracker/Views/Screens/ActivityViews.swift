import SwiftUI
import SwiftData

// MARK: - Activity feed

struct ActivityView: View {
    enum Filter: Hashable { case all, review, noReceipt, moneyIn }
    @State private var filter = Filter.all

    var body: some View {
        WithLedger { ledger in
            let entries = ledger.activityFeed()
            let shown = entries.filter(test)
            Screen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        chip(.all, "All", entries.count, show: false)
                        chip(.review, "Check match", entries.filter { $0.status == "needs_review" }.count)
                        chip(.noReceipt, "No receipt", entries.filter { $0.status == "unmatched" }.count)
                        chip(.moneyIn, "Money in", entries.filter(\.isIncoming).count)
                    }
                }
                .padding(.top, 4)
                if shown.isEmpty {
                    EmptyCard(entries.isEmpty ? "No transactions yet" : "Nothing matches that filter",
                              entries.isEmpty ? "Upload a YouTrip screenshot and your charges will show up here." : nil) {
                        if entries.isEmpty { NavigationLink(value: Route.add) { Text("Add screenshots").font(.rounded(15, .semibold)).foregroundStyle(Theme.accent) } }
                    }
                } else { GroupedFeed(entries: shown) }
            }
            .overlay(alignment: .bottomTrailing) {
                NavigationLink(value: Route.add) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(Theme.accent, in: Circle()).shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 5)
                }.padding(20)
            }
        }
        .navigationTitle("Activity")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: Route.search) { Image(systemName: "magnifyingglass") } } }
    }

    private func test(_ e: ActivityEntry) -> Bool {
        switch filter {
        case .all: true
        case .review: e.status == "needs_review"
        case .noReceipt: e.status == "unmatched"
        case .moneyIn: e.isIncoming
        }
    }

    private func chip(_ value: Filter, _ label: String, _ count: Int, show: Bool = true) -> some View {
        Button { filter = value } label: {
            Text(label + (show && count > 0 ? " \(count)" : "")).font(.rounded(13, .semibold)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(filter == value ? .white : Theme.muted)
                .background(filter == value ? Theme.accent : Theme.surface, in: Capsule())
                .overlay { Capsule().stroke(Theme.line) }
        }.buttonStyle(.plain)
    }
}

// MARK: - Transaction detail

struct TransactionView: View {
    let transaction: YouTripTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster
    @State private var note = ""
    @State private var loadedNote = false
    @State private var pickingTrip = false
    @State private var pickingCategory = false
    @State private var linking = false
    @State private var confirmDelete = false
    @State private var openItemID: String?
    @State private var selecting = false
    @State private var selected = Set<String>()
    @FocusState private var noteFocused: Bool

    var body: some View {
        WithLedger { ledger in
            let t = transaction
            let items = ledger.items(of: t)
            let real = items.filter { !$0.isDeposit }
            let incoming = t.transactionType != .expense
            let personal = real.reduce(0) { $0 + ($1.personalSGD ?? 0) }, others = real.reduce(0) { $0 + ($1.othersSGD ?? 0) }
            let single = real.count == 1 ? real[0] : nil
            let itemised = t.matchedReceipt?.isItemised ?? false

            Screen {
                hero(t, incoming: incoming, single: single, count: real.count, ledger: ledger)
                if t.status == "needs_review" { reviewCard(t) }
                if incoming {
                    Rows {
                        NavigationLink(value: Route.classify(t)) {
                            MenuRow(TransactionRow.incomingLabel[t.transactionType] ?? "Money in",
                                    hint: partialHint(t)) { Text("change").font(.rounded(13)).foregroundStyle(Theme.muted) }
                        }.buttonStyle(.plain)
                    }.flushCard()
                } else {
                    Rows {
                        NavigationLink(value: Route.split(t)) {
                            MenuRow("Split / Paid for others") {
                                if others > 0.005 { Text("you \(Money.string(personal)) · others \(Money.string(others))").font(.rounded(12)).foregroundStyle(Theme.muted) }
                            }
                        }.buttonStyle(.plain)
                        if let receipt = t.matchedReceipt {
                            NavigationLink(value: Route.receipt(receipt)) {
                                MenuRow(receipt.merchant.map { "Receipt · \($0)" } ?? "Receipt") {
                                    Text(t.matchStatus == "approved" ? "confirmed" : "matched").font(.rounded(12)).foregroundStyle(Theme.muted)
                                }
                            }.buttonStyle(.plain)
                        } else {
                            Button { linking = true } label: { MenuRow("Add receipt", hint: "Link one you’ve uploaded, or upload it now") }.buttonStyle(.plain)
                        }
                        if !itemised {
                            NavigationLink(value: Route.breakdown(t)) {
                                MenuRow("Break down into categories", hint: "e.g. a Splitwise settlement made of food, transport and souvenirs")
                            }.buttonStyle(.plain)
                        }
                        NavigationLink(value: Route.classify(t)) { MenuRow("Not a purchase?", hint: "Mark it as money in, a refund, or a transfer") }.buttonStyle(.plain)
                    }.flushCard()
                }
                if real.count > 1 || (real.count == 1 && itemised) {
                    SectionTitle("Items")
                    ItemList(items: items, selecting: $selecting, selected: $selected) { openItemID = $0.id }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes").font(.rounded(15, .bold))
                    TextField("Add a note", text: $note, axis: .vertical).lineLimit(2...6).focused($noteFocused)
                        .padding(10).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.card()
            }
            .navigationTitle("Transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu { Button("Delete transaction", systemImage: "trash", role: .destructive) { confirmDelete = true } } label: { Image(systemName: "ellipsis.circle") }
            } }
            .sheet(isPresented: $pickingTrip) { TripPicker(current: t.trip) { Actions.assign(t, to: $0, in: context); toaster.show("Trip updated") } }
            .sheet(isPresented: $pickingCategory) {
                if let single {
                    CategoryPicker(title: "Category", selected: single.category, allowClear: true, teach: true) { category, remember, similar in
                        Actions.assignCategory([single], to: category, alsoSimilar: similar, remember: remember, ledger: ledger, in: context)
                        toaster.show(category.map { "Moved to \($0.name)" } ?? "Cleared")
                    }
                }
            }
            .sheet(isPresented: $linking) { linkSheet(ledger) }
            .sheet(isPresented: Binding(get: { openItemID != nil }, set: { if !$0 { openItemID = nil } })) { if let id = openItemID { ItemSheet(itemID: id) } }
            .confirmationDialog("Delete this transaction? This removes it from your history and your totals.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Actions.delete(t, in: context); toaster.show("Deleted"); dismiss() }
            }
        }
        .onAppear { if !loadedNote { note = transaction.userNote ?? ""; loadedNote = true } }
        .onChange(of: noteFocused) { _, focused in if !focused { Actions.setNote(transaction, note, in: context) } }
        .onDisappear { if (transaction.userNote ?? "") != note.trimmingCharacters(in: .whitespacesAndNewlines) { Actions.setNote(transaction, note, in: context) } }
    }

    private func partialHint(_ t: YouTripTransaction) -> String? {
        guard t.transactionType == .reimbursement, let part = t.reimbursementAmount, part < (t.amountSGD ?? 0) - 0.005 else { return nil }
        return "\(Money.string(part)) counted as reimbursement, the rest as income"
    }

    private func hero(_ t: YouTripTransaction, incoming: Bool, single: ItemView?, count: Int, ledger: Ledger) -> some View {
        let local = t.localAmount.map { "\(t.localCurrency ?? "") \(String(format: "%.2f", $0))".trimmingCharacters(in: .whitespaces) }
        return VStack(spacing: 5) {
            if incoming { IconTile(symbol: "⬇️", color: Theme.good, size: 56) }
            else { IconTile(symbol: single?.category?.icon ?? "🧾", color: single?.category.map { Color(hex: $0.effectiveColorHex) } ?? Theme.miscColor, size: 56) }
            Text(t.transactionDescription ?? "Unknown charge").font(.rounded(20, .bold)).multilineTextAlignment(.center)
            Text([t.date?.formatted(.dateTime.day().month(.abbreviated).year()), t.trip?.name].compactMap { $0 }.joined(separator: " · ")).font(.rounded(13)).foregroundStyle(Theme.muted)
            Text(incoming ? Money.string(t.amountSGD, sign: true) : Money.string(-(t.amountSGD ?? 0))).font(.rounded(36, .heavy)).foregroundStyle(incoming ? Theme.good : Theme.text)
            Text((["YouTrip · SGD"] + (local.map { ["charged \($0)"] } ?? [])).joined(separator: " · ")).font(.rounded(12)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                if !incoming {
                    Button { pickingTrip = true } label: {
                        Text(t.trip.map { "🧳 \($0.name)" } ?? "+ Trip").font(.rounded(13, .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(t.trip == nil ? Theme.muted : .white).background(t.trip == nil ? Color.clear : Theme.accent, in: Capsule())
                            .overlay { if t.trip == nil { Capsule().strokeBorder(Theme.mutedLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
                    }
                }
                if let single { Button { pickingCategory = true } label: { CategoryChip(category: single.category, confidence: single.confidence, full: true) } }
                else if count > 1 { MiniChip(text: "\(count) items") }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private func reviewCard(_ t: YouTripTransaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worth a look").font(.rounded(15, .bold))
            Text(t.matchNote ?? "This charge was linked to a receipt, but the match isn’t certain.").font(.rounded(13))
            HStack {
                Button("Looks right") { Actions.approve(t, in: context); toaster.show("Approved") }.buttonStyle(.borderedProminent)
                Button("Unlink") { Actions.unlink(t, in: context); toaster.show("Unlinked") }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.orangeBg, bordered: false)
    }

    private func linkSheet(_ ledger: Ledger) -> some View {
        NavigationStack {
            ScrollView {
                let receipts = ledger.unmatchedReceipts
                if receipts.isEmpty {
                    VStack(spacing: 12) {
                        Text("No unmatched receipts right now.").foregroundStyle(Theme.muted)
                        NavigationLink(value: Route.add) { Text("Upload a receipt").font(.rounded(15, .semibold)) }
                    }.padding(30)
                } else {
                    Rows {
                        ForEach(receipts) { r in
                            Button { Actions.link(transaction, to: r, in: context); linking = false; toaster.show("Linked") } label: {
                                MenuRow(r.merchant ?? "Unknown store", hint: [r.date?.formatted(.dateTime.day().month(.abbreviated)), r.total.map { "\(r.currency ?? "") \(String(format: "%.2f", $0))" }].compactMap { $0 }.joined(separator: " · "), chevron: false)
                            }.buttonStyle(.plain)
                        }
                    }.flushCard().padding(16)
                }
            }
            .screenBackground().navigationTitle("Link a receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { linking = false } } }
            .appDestinations()
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Receipt only

struct ReceiptView: View {
    let receipt: Receipt
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var pickingTrip = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var openItemID: String?

    var body: some View {
        WithLedger { ledger in
            let items = ledger.items(of: receipt)
            let total = items.filter { !$0.isDeposit }.reduce(0) { $0 + ($1.priceSGD ?? 0) }
            let linked = ledger.transactions.first { $0.matchedReceipt?.persistentModelID == receipt.persistentModelID }
            Screen {
                VStack(alignment: .leading, spacing: 6) {
                    Text(receipt.date?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "No date").font(.rounded(13)).foregroundStyle(Theme.muted)
                    Text(Money.string(total)).font(.rounded(32, .heavy))
                    if let c = receipt.currency, c != "SGD" { Text("printed in \(c)").font(.rounded(12)).foregroundStyle(Theme.muted) }
                    Button { pickingTrip = true } label: { Text(receipt.trip.map { "🧳 \($0.name)" } ?? "+ Trip").font(.rounded(13, .semibold)) }
                }.frame(maxWidth: .infinity, alignment: .leading).card()
                if let image = storedImage { image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                if let linked { NavigationLink(value: Route.transaction(linked)) { MenuRow("Open the linked transaction") }.buttonStyle(.plain).flushCard() }
                else { candidates(ledger) }
                SectionTitle("Items")
                ItemList(items: items, selecting: $selecting, selected: $selected) { openItemID = $0.id }
            }
            .navigationTitle(receipt.merchant ?? "Receipt").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $pickingTrip) { TripPicker(current: receipt.trip) { Actions.assign(receipt, to: $0, in: context); toaster.show("Trip updated") } }
            .sheet(isPresented: Binding(get: { openItemID != nil }, set: { if !$0 { openItemID = nil } })) { if let id = openItemID { ItemSheet(itemID: id) } }
        }
    }

    private var storedImage: Image? {
        guard let path = receipt.sourceImagePath, !path.isEmpty,
              let image = UIImage(contentsOfFile: URL.documentsDirectory.appending(path: path).path) else { return nil }
        return Image(uiImage: image)
    }

    @ViewBuilder
    private func candidates(_ ledger: Ledger) -> some View {
        let open = ledger.unmatchedCharges
        VStack(alignment: .leading, spacing: 8) {
            Text("No charge linked yet").font(.rounded(15, .bold))
            Text("It still counts in your spending. Link the matching YouTrip charge once you’ve uploaded it.").font(.rounded(13)).foregroundStyle(Theme.muted)
            if open.isEmpty { Text("No unlinked charges to pair it with.").font(.rounded(13)).foregroundStyle(Theme.muted) }
            else {
                Rows {
                    ForEach(open.prefix(8)) { t in
                        Button { Actions.link(t, to: receipt, in: context); toaster.show("Linked") } label: {
                            MenuRow(t.transactionDescription ?? "Charge", hint: t.date?.formatted(.dateTime.day().month(.abbreviated)), chevron: false) { Text(Money.string(t.amountSGD)).font(.rounded(14, .bold)) }
                        }.buttonStyle(.plain)
                    }
                }.flushCard()
            }
        }.card()
    }
}

// MARK: - Split / paid for others

struct SplitView: View {
    let transaction: YouTripTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster
    @State private var custom = false
    @State private var people = 2
    @State private var shareText = ""
    @State private var loaded = false

    var body: some View {
        WithLedger { ledger in
            let total = transaction.amountSGD ?? 0
            let items = ledger.items(of: transaction).filter { !$0.isDeposit }
            let existing = items.reduce(0) { $0 + ($1.othersSGD ?? 0) } > 0.005
            let mine = myShare(total)
            let others = round2(total - mine)
            let valid = mine >= -0.005 && mine <= total + 0.005
            let single = items.count == 1 ? items[0] : nil
            let where_ = single?.category.map { $0.path.suffix(2).joined(separator: " › ") } ?? (items.count > 1 ? "your categories" : "Unsorted")

            Screen {
                Text(transaction.transactionDescription ?? "Transaction").font(.rounded(13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                SegmentedTabs(options: [(false, "Split equally"), (true, "Custom")], selection: Binding(get: { custom }, set: { new in
                    if new && !custom { shareText = String(format: "%.2f", mine) }
                    custom = new
                }))
                Rows {
                    row("Total amount") { Text(Money.string(total)).font(.rounded(16, .bold)) }
                    if !custom {
                        row("Number of people (including you)") {
                            HStack(spacing: 12) {
                                Button { people = max(2, people - 1) } label: { Image(systemName: "minus").frame(width: 34, height: 34).background(Theme.segBg, in: Circle()) }
                                Text("\(people)").font(.rounded(16, .bold))
                                Button { people = min(30, people + 1) } label: { Image(systemName: "plus").frame(width: 34, height: 34).background(Theme.segBg, in: Circle()) }
                            }.buttonStyle(.plain)
                        }
                    }
                    row("Your share") {
                        if custom {
                            HStack(spacing: 2) { Text("$"); TextField("0.00", text: $shareText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90) }
                                .font(.rounded(16, .bold))
                        } else { Text(Money.string(mine)).font(.rounded(16, .bold)) }
                    }
                    row("Paid for others") { Text(Money.string(others)).font(.rounded(16, .bold)) }.background(Theme.orangeBg)
                }.flushCard()
                VStack(alignment: .leading, spacing: 6) {
                    Text("This will be recorded as:").font(.rounded(14, .bold))
                    Text("• \(Money.string(mine)) in \(where_)").font(.rounded(13))
                    Text("• \(Money.string(others)) in Paid for others (not in spending)").font(.rounded(13))
                    Text("The transaction stays \(Money.string(total)) in your cash history.").font(.rounded(12)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.blueBg, bordered: false)
                if !valid { Text("Your share has to be between $0 and \(Money.string(total)).").font(.rounded(13)).foregroundStyle(Theme.bad) }
                PrimaryButton(title: "Confirm", disabled: !valid) {
                    do {
                        try Actions.setTransactionSplit(transaction, myShare: min(max(mine, 0), total), in: context)
                        toaster.show(others > 0.005 ? "\(Money.string(others)) recorded as paid for others" : "Split cleared")
                        dismiss()
                    } catch { toaster.show(error.localizedDescription, error: true) }
                }
                if existing {
                    QuietButton(title: "Remove split (all mine)") {
                        try? Actions.setTransactionSplit(transaction, myShare: total, in: context); toaster.show("Split cleared"); dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if existing { custom = true; shareText = String(format: "%.2f", items.reduce(0) { $0 + ($1.personalSGD ?? 0) }) }
            }
        }
        .navigationTitle("Split / Paid for others").navigationBarTitleDisplayMode(.inline)
    }

    private func myShare(_ total: Double) -> Double {
        custom ? (Double(shareText.replacingOccurrences(of: ",", with: ".")) ?? 0) : round2(total / Double(people))
    }

    private func row<T: View>(_ label: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack { Text(label).font(.rounded(15)); Spacer(minLength: 8); trailing() }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 52).rowDivider()
    }
}

// MARK: - Incoming money

struct ClassifyView: View {
    let transaction: YouTripTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster
    @State private var type = TransactionType.reimbursement
    @State private var excessAsIncome = true
    @State private var refundOf: Receipt?
    @State private var loaded = false

    private static let options: [(TransactionType, String, String, String)] = [
        (.reimbursement, "🤝", "Reimbursement", "Reduces your “owed back” balance"),
        (.income, "💰", "Allowance / Income", "Adds to your funds, not a reimbursement"),
        (.transferOwnAccount, "🔁", "Transfer (my own account)", "Neither spending nor income"),
        (.refund, "↩️", "Refund", "For a previous purchase"),
        (.other, "•", "Other", "Something else"),
    ]

    var body: some View {
        WithLedger { ledger in
            let amount = abs(transaction.amountSGD ?? 0)
            let outstanding = ledger.outstanding(excluding: transaction)
            let owed = max(outstanding, 0)
            let excess = type == .reimbursement && amount > owed + 0.005
            let personToPerson = (transaction.transactionDescription ?? "").range(of: #"^(from|paynow|transfer|received|paylah|venmo)"#, options: [.regularExpression, .caseInsensitive]) != nil

            Screen {
                VStack(spacing: 4) {
                    IconTile(symbol: "⬇️", color: Theme.good, size: 52)
                    Text(Money.string(amount, sign: true)).font(.rounded(34, .heavy)).foregroundStyle(Theme.good)
                    Text(transaction.transactionDescription ?? "Unknown").font(.rounded(16, .bold))
                    Text(transaction.date?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "").font(.rounded(13)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity)
                Text("What is this?").font(.rounded(18, .bold))
                Rows {
                    ForEach(Self.options, id: \.0) { option in
                        Button { type = option.0 } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: option.1, color: Theme.good, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(option.2).font(.rounded(15, .semibold))
                                        if option.0 == .reimbursement && personToPerson && transaction.transactionType == .expense { Text("suggested").font(.rounded(11, .bold)).foregroundStyle(Theme.good) }
                                    }
                                    Text(option.3).font(.rounded(12)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if type == option.0 { Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.bold) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(type == option.0 ? Theme.good.opacity(0.1) : Color.clear).rowDivider()
                        }.buttonStyle(.plain)
                    }
                }.flushCard()

                if excess {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(owed > 0 ? "Only \(Money.string(owed)) is currently owed back" : "Nothing is currently owed back").font(.rounded(15, .bold))
                        Text("A reimbursement can’t push what you’re owed below zero. What about the extra?").font(.rounded(13))
                        choice(owed > 0 ? "Count the extra \(Money.string(amount - owed)) as income" : "Count all of it as income", selected: excessAsIncome) { excessAsIncome = true }
                        choice("It’s all reimbursement: my earlier records were incomplete", selected: !excessAsIncome) { excessAsIncome = false }
                    }.frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.orangeBg, bordered: false)
                }
                if type == .refund {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Which purchase is this refunding?", selection: $refundOf) {
                            Text("I’m not sure").tag(Receipt?.none)
                            ForEach(ledger.transactions.filter { $0.transactionType == .expense && $0.matchedReceipt != nil && $0 !== transaction }) { t in
                                Text("\(t.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "") · \(t.transactionDescription ?? "") · \(Money.string(t.amountSGD))").tag(Optional(t.matchedReceipt!))
                            }
                        }
                        Text("Linking it keeps the record straight. Category totals aren’t netted automatically yet.").font(.rounded(12)).foregroundStyle(Theme.muted)
                    }.card()
                }
                PrimaryButton(title: "Save") { save(amount: amount, owed: owed, excess: excess) }
                if transaction.transactionType != .expense {
                    QuietButton(title: "Actually, this was a purchase") {
                        try? Actions.classify(transaction, as: .expense, in: context); toaster.show("Back to a normal purchase"); dismiss()
                    }
                }
            }
        }
        .navigationTitle("Incoming transaction").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if transaction.transactionType != .expense { type = transaction.transactionType; refundOf = transaction.refundsReceipt }
        }
    }

    private func choice(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.accent : Theme.muted); Text(text).font(.rounded(14)).multilineTextAlignment(.leading) }
        }.buttonStyle(.plain)
    }

    private func save(amount: Double, owed: Double, excess: Bool) {
        var finalType = type
        var part: Double?
        if type == .reimbursement && excess && excessAsIncome { if owed <= 0.005 { finalType = .income } else { part = owed } }
        do {
            try Actions.classify(transaction, as: finalType, refunds: finalType == .refund ? refundOf : nil, reimbursementAmount: part, in: context)
            toaster.show("Saved"); dismiss()
        } catch { toaster.show(error.localizedDescription, error: true) }
    }
}

// MARK: - Manual breakdown

struct BreakdownView: View {
    let transaction: YouTripTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster

    struct DraftRow: Identifiable { let id = UUID(); var category: Category?; var amount = "" }
    @State private var rows: [DraftRow] = []
    @State private var pickingRow: UUID?
    @State private var loaded = false

    var body: some View {
        WithLedger { ledger in
            let total = transaction.amountSGD ?? 0
            let assigned = rows.reduce(0) { $0 + (Double($1.amount.replacingOccurrences(of: ",", with: ".")) ?? 0) }
            let remaining = round2(total - assigned)
            Screen {
                if transaction.matchedReceipt?.isItemised == true {
                    EmptyCard("This one’s already itemised", "A receipt read from a photo already splits it into items.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(transaction.transactionDescription ?? "Transaction") · \(Money.string(total))").font(.rounded(15, .bold))
                        Text("Say what this payment was made of, for example a Splitwise settlement covering food, transport and souvenirs. These amounts are the same money, not extra, so your total doesn’t change. Anything you leave out stays Unsorted.")
                            .font(.rounded(13)).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.blueBg, bordered: false)
                    VStack(spacing: 10) {
                        ForEach($rows) { $row in
                            HStack(spacing: 8) {
                                Button { pickingRow = row.id } label: {
                                    HStack { if let c = row.category { CategoryChip(category: c, confidence: .confirmed, full: true) } else { Text("Choose category").foregroundStyle(Theme.muted).font(.rounded(14)) }; Spacer(minLength: 0) }
                                }.buttonStyle(.plain)
                                HStack(spacing: 2) { Text("$"); TextField("0.00", text: $row.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70) }.font(.rounded(15, .bold))
                                Button { rows.removeAll { $0.id == row.id }; if rows.isEmpty { rows = [DraftRow()] } } label: { Image(systemName: "xmark").foregroundStyle(Theme.muted) }.buttonStyle(.plain)
                            }
                        }
                        Button { rows.append(DraftRow()) } label: { Text("+ Add another").font(.rounded(14, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.bordered)
                    }.card()
                    Rows {
                        summary("Charged", Money.string(total))
                        summary("Assigned", Money.string(assigned))
                        summary(remaining < -0.005 ? "Over by" : "Left as Unsorted", Money.string(abs(remaining)), bad: remaining < -0.005)
                    }.flushCard()
                    PrimaryButton(title: "Save breakdown", disabled: assigned <= 0 || remaining < -0.005) {
                        let parts = rows.compactMap { r -> BreakdownPart? in
                            guard let amount = Double(r.amount.replacingOccurrences(of: ",", with: ".")), amount > 0 else { return nil }
                            return BreakdownPart(category: r.category, amount: amount, name: r.category?.name)
                        }
                        do { try Actions.breakdown(transaction, parts: parts, in: context); toaster.show("Broken down"); dismiss() }
                        catch { toaster.show(error.localizedDescription, error: true) }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { pickingRow != nil }, set: { if !$0 { pickingRow = nil } })) {
                CategoryPicker(title: "Category", selected: rows.first { $0.id == pickingRow }?.category) { category, _, _ in
                    if let i = rows.firstIndex(where: { $0.id == pickingRow }) { rows[i].category = category }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let existing = ledger.items(of: transaction).filter { $0.name != "Unsorted remainder" && $0.category != nil && !$0.isVirtual }
                rows = existing.isEmpty ? [DraftRow()] : existing.map { DraftRow(category: $0.category, amount: String(format: "%.2f", $0.priceSGD ?? $0.price)) }
            }
        }
        .navigationTitle("Break down").navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ label: String, _ value: String, bad: Bool = false) -> some View {
        HStack { Text(label).font(.rounded(15)); Spacer(); Text(value).font(.rounded(15, .bold)).foregroundStyle(bad ? Theme.bad : Theme.text) }
            .padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
    }
}
