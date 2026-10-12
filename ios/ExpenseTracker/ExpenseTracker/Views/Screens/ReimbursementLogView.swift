import SwiftUI
import SwiftData

/// A trip's reimbursement log: what you owe for things others paid (logged by hand, any time during the trip), what you're owed for
/// things you paid for others, and the payments between you. When the payments arrive they're checked against the log.
struct ReimbursementLogView: View {
    let trip: Trip
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var adding: AddTarget?
    @State private var editing: SharedCost?
    @State private var targetedDay: String?

    struct AddTarget: Identifiable { let date: Date?; var id: String { date.map { "\($0.timeIntervalSince1970)" } ?? "none" } }

    var body: some View {
        WithLedger { ledger in
            let log = ledger.tripLog(trip)
            Screen {
                summary(log)
                if !log.paidFor.isEmpty {
                    SectionTitle("Paid for others") { Text("+ \(Money.string(log.owedToYou))").font(.rounded(13, .bold)).foregroundStyle(Theme.good) }
                    Rows { ForEach(log.paidFor) { item in
                        NavigationLink(value: item.transaction.map(Route.transaction) ?? Route.reimbursementLog(trip)) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.rounded(15, .semibold)).lineLimit(1)
                                    Text("\(item.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "") · yours \(Money.string(item.personalSGD))").font(.rounded(12)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text("+" + Money.string(item.othersSGD)).font(.rounded(15, .bold)).foregroundStyle(Theme.good)
                            }.padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                        }.buttonStyle(.plain)
                    } }.flushCard()
                }
                SectionTitle("What you owe") { Text("− \(Money.string(log.owed))").font(.rounded(13, .bold)).foregroundStyle(Theme.bad) }
                ForEach(TripDays.slots(trip: trip, costs: log.costs), id: \.self) { day in
                    daySection(day, costs: log.costs.filter { $0.date?.startOfDay == day })
                }
                daySection(nil, costs: log.costs.filter { $0.date == nil })
                SectionTitle("Paid") { Text(Money.string(log.paid)).font(.rounded(13, .bold)) }
                if log.payments.isEmpty {
                } else {
                    Rows { ForEach(log.payments) { t in
                        NavigationLink(value: Route.transaction(t)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("To \(t.payee ?? "")").font(.rounded(15, .semibold))
                                    Text(t.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.rounded(12)).foregroundStyle(Theme.muted)
                                }
                                Spacer(); Text(Money.string(abs(t.amountSGD ?? 0))).font(.rounded(15, .bold))
                            }.padding(.horizontal, 14).padding(.vertical, 12).rowDivider()
                        }.buttonStyle(.plain)
                    } }.flushCard()
                }
            }
            .navigationTitle("Reimbursement log").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $adding) { SharedCostSheet(trip: trip, editing: nil, defaultDate: $0.date) }
            .sheet(item: $editing) { SharedCostSheet(trip: trip, editing: $0) }
        }
    }

    private func costRow(_ cost: SharedCost) -> some View {
        Button { editing = cost } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cost.title).font(.rounded(15, .semibold)).lineLimit(2)
                    Text([cost.person.map { "owed to \($0)" }, cost.remark].compactMap { $0 }.joined(separator: " · ")).font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(2)
                    CategoryChip(category: cost.category, confidence: cost.category == nil ? .unknown : .confirmed)
                }
                Spacer()
                Text("−" + Money.string(cost.amountSGD)).font(.rounded(15, .bold)).foregroundStyle(Theme.bad)
            }.padding(.horizontal, 14).padding(.vertical, 10).rowDivider()
        }.buttonStyle(.plain)
        .draggable("cost:" + cost.uid) {
            Text("\(cost.title) · \(Money.string(cost.amountSGD))").font(.rounded(13, .semibold)).padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(radius: 4)
        }
    }

    /// One day of the trip: a header with its total and a + for that day, and the costs on it. Also where a dragged cost lands.
    private func daySection(_ day: Date?, costs: [SharedCost]) -> some View {
        let key = day.map { "\($0.timeIntervalSince1970)" } ?? "none"
        let total = costs.reduce(0) { $0 + $1.amountSGD }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.map { $0.formatted(.dateTime.month(.abbreviated).day()).uppercased() } ?? "NO DAY YET").font(.rounded(13, .bold)).tracking(0.4)
                    if let day, let n = TripDays.dayNumber(day, trip: trip) { Text("Day \(n)").font(.rounded(11)).foregroundStyle(Theme.muted) }
                }
                Spacer()
                if total > 0 { Text("−" + Money.string(total)).font(.rounded(13, .bold)).foregroundStyle(Theme.bad) }
                Button { adding = AddTarget(date: day) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain).accessibilityLabel("Add a cost" + (day.map { " on \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""))
            }.padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(costs) { costRow($0) }
            if costs.isEmpty { Text("Drop one here, or tap +").font(.rounded(11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.bottom, 10) }
        }
        .background(targetedDay == key ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(targetedDay == key ? Theme.accent : Theme.line, lineWidth: targetedDay == key ? 2 : 1) }
        .dropDestination(for: String.self) { items, _ in
            let uids = items.filter { $0.hasPrefix("cost:") }.map { String($0.dropFirst(5)) }
            guard !uids.isEmpty else { return false }
            for uid in uids { Actions.moveSharedCost(uid: uid, to: day, in: context) }
            toaster.show("Moved to " + (day.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "no day"))
            return true
        } isTargeted: { targetedDay = $0 ? key : (targetedDay == key ? nil : targetedDay) }
    }

    /// The net that should change hands, and the check against what did.
    private func summary(_ log: Ledger.TripLog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(log.net > 0 ? "Net to pay" : (log.net < 0 ? "Net owed to you" : "Net")).font(.rounded(12)).foregroundStyle(Theme.muted)
            Text(Money.string(abs(log.net))).font(.rounded(36, .heavy))
            Text("\(Money.string(log.owed)) you owe, minus \(Money.string(log.owedToYou)) you paid for others").font(.rounded(12)).foregroundStyle(Theme.muted)
            Divider()
            if log.payments.isEmpty {
                Text(log.owed > 0 ? "Not paid yet. This is what the payments should come to." : "Log what you owe as you go. When you pay, it’s checked here.")
                    .font(.rounded(14))
            } else if log.balanced {
                Label("Paid \(Money.string(log.paid)): it matches (allowing for rounding)", systemImage: "checkmark.circle.fill").font(.rounded(14, .semibold)).foregroundStyle(Theme.good)
            } else if log.unaccounted > 0 {
                Text("Paid \(Money.string(log.paid)) · \(Money.string(max(0, log.net))) logged · **\(Money.string(log.unaccounted)) unaccounted**").font(.rounded(14))
                Text("You paid more than you’ve logged. Check your Tricount for what’s missing, or leave it: it counts as unsorted spending until you do.").font(.rounded(12)).foregroundStyle(Theme.muted)
            } else {
                Text("Paid \(Money.string(log.paid)) · \(Money.string(log.stillToPay)) still to pay").font(.rounded(14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(background: log.balanced ? Theme.greenBg : Theme.blueBg, bordered: false)
    }
}

/// One thing you owe. Optional date and remark, since a typed-in list gets wonky ("D2 water at convenience store").
struct SharedCostSheet: View {
    let trip: Trip
    let editing: SharedCost?
    var defaultDate: Date? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @Query private var existing: [SharedCost]
    @State private var title = ""
    @State private var amount = ""
    @State private var person = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var remark = ""
    @State private var category: Category?
    @State private var pickingCategory = false
    @FocusState private var titleFocused: Bool

    private var people: [String] { Array(Set(existing.compactMap(\.person))).sorted() }

    var body: some View {
        NavigationStack {
            Form {
                Section("What was it?") { TextField("e.g. Medieval dinner", text: $title).focused($titleFocused) }
                Section("Your share") { HStack { Text("$"); TextField("0.00", text: $amount).keyboardType(.decimalPad) } }
                Section("Who paid for it? (optional)") {
                    TextField("Name", text: $person)
                    if !people.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(people, id: \.self) { name in Button(name) { person = name }.buttonStyle(.bordered).controlSize(.small) } }
                        }
                    }
                }
                Section("Category") {
                    Button { pickingCategory = true } label: {
                        HStack { CategoryChip(category: category, confidence: category == nil ? .unknown : .confirmed, full: true); Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.muted) }
                    }
                }
                Section {
                    Toggle("Day", isOn: $hasDate)
                    if hasDate { DatePicker("When", selection: $date, displayedComponents: .date) }
                    TextField("Remark (optional)", text: $remark)
                } footer: { Text("Without a day it sits under “No day yet”, and counts at the end of the trip.") }
                if editing != nil {
                    Section { Button("Delete", role: .destructive) { if let editing { Actions.deleteSharedCost(editing, in: context) }; dismiss() } }
                }
            }
            .navigationTitle(editing == nil ? "What I owe" : "Edit").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(editing == nil ? "Add" : "Save") { if save() { dismiss() } } }
                if editing == nil { ToolbarItem(placement: .bottomBar) { Button("Add and do another") { if save() { reset() } } } }
            }
            .sheet(isPresented: $pickingCategory) { CategoryPicker(title: "Category", selected: category) { picked, _, _ in category = picked } }
            .onAppear {
                if let editing {
                    title = editing.title; amount = String(format: "%.2f", editing.amountSGD); person = editing.person ?? ""; remark = editing.remark ?? ""
                    category = editing.category
                    if let d = editing.date { hasDate = true; date = d }
                } else {
                    if let defaultDate { hasDate = true; date = defaultDate }
                    titleFocused = true
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() -> Bool {
        let value = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        do {
            if let editing {
                let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, value > 0 else { throw AppError(clean.isEmpty ? "Say what it was." : "Enter what you owe for it.") }
                editing.title = clean; editing.amountSGD = round2(value); editing.person = person.trimmingCharacters(in: .whitespaces).nilIfEmpty
                editing.remark = remark.trimmingCharacters(in: .whitespaces).nilIfEmpty; editing.category = category; editing.date = hasDate ? date : nil
                try? context.save()
            } else {
                try Actions.addSharedCost(title: title, amount: value, date: hasDate ? date : nil, remark: remark, person: person, category: category, trip: trip, in: context)
            }
            return true
        } catch { toaster.show(error.localizedDescription, error: true); return false }
    }

    /// Keeps the person, date and category (a run of costs often shares them) and clears what differs.
    private func reset() { title = ""; amount = ""; remark = ""; titleFocused = true; toaster.show("Added") }
}
