import SwiftUI
import SwiftData

private let tripEmoji = ["🏰", "🗼", "🏔️", "🏖️", "🌆", "🚂", "🎌", "🌲", "🛳️", "🎡"]
private let tripColors = ["5d8df6", "ff8a75", "4fd1a5", "b36cf0", "ffb066", "f58bd0"]

extension Trip {
    var tint: Color { Color(hex: colorHex ?? "5d8df6") }
    var banner: LinearGradient {
        LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var dateRange: String {
        let parts = [startDate, endDate].compactMap { $0?.formatted(.dateTime.day().month(.abbreviated)) }
        return parts.isEmpty ? "No dates yet" : parts.joined(separator: " – ")
    }
}

// MARK: - Create / edit a trip

struct TripEditSheet: View {
    var trip: Trip?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var name = ""
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(86_400 * 5)
    @State private var emoji = "🧳"
    @State private var colorHex = tripColors[0]
    @State private var activate = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. Tallinn trip", text: $name) }
                Section("Dates") {
                    Toggle("Starts", isOn: $hasStart); if hasStart { DatePicker("", selection: $start, displayedComponents: .date).labelsHidden() }
                    Toggle("Ends", isOn: $hasEnd); if hasEnd { DatePicker("", selection: $end, displayedComponents: .date).labelsHidden() }
                }
                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(tripEmoji, id: \.self) { e in
                            Text(e).font(.system(size: 28)).padding(6).background(e == emoji ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10)).onTapGesture { emoji = e }
                        } }
                    }
                }
                Section("Colour") {
                    HStack { ForEach(tripColors, id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 30, height: 30).overlay { if hex == colorHex { Circle().stroke(Theme.text, lineWidth: 3) } }.onTapGesture { colorHex = hex }
                    } }
                }
                if trip == nil { Section { Toggle("Turn on Trip Mode now", isOn: $activate) } footer: { Text("New transactions tag themselves with this trip.") } }
            }
            .navigationTitle(trip == nil ? "New trip" : "Trip settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(trip == nil ? "Create" : "Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear {
                guard let trip else { return }
                name = trip.name; emoji = trip.emoji ?? "🧳"; colorHex = trip.colorHex ?? tripColors[0]
                if let s = trip.startDate { hasStart = true; start = s }
                if let e = trip.endDate { hasEnd = true; end = e }
            }
        }
    }

    private func save() {
        do {
            if let trip {
                trip.name = name.trimmingCharacters(in: .whitespaces); trip.emoji = emoji; trip.colorHex = colorHex
                trip.startDate = hasStart ? start.startOfDay : nil; trip.endDate = hasEnd ? end.startOfDay : nil
                try? context.save(); toaster.show("Saved")
            } else {
                try Actions.createTrip(name: name, start: hasStart ? start.startOfDay : nil, end: hasEnd ? end.startOfDay : nil,
                                       activate: activate, colorHex: colorHex, emoji: emoji, in: context)
                toaster.show("Trip created")
            }
            dismiss()
        } catch { toaster.show(error.localizedDescription, error: true) }
    }
}

// MARK: - Travel

struct TravelView: View {
    enum Mode { case trips, spending }
    @State private var mode = Mode.trips
    @State private var creating = false

    var body: some View {
        WithLedger { ledger in
            let summary = ledger.travelSummary()
            let active = ledger.activeTrip
            let peak = max(1, summary.categories.map(\.spend).max() ?? 1)
            Screen {
                HStack(spacing: 14) {
                    IconTile(symbol: "✈️", color: Color(hex: "5d8df6"), size: 52)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Money.whole(summary.total)).font(.rounded(30, .heavy))
                        Text("\(String(format: "%.1f", summary.shareOfSpending))% of your spending").font(.rounded(13)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }.padding(16).background(Color(hex: "5d8df6").opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                NavigationLink(value: Route.tripMode) {
                    HStack { Text("🧳"); Text(active.map { "Trip Mode is on · \($0.name)" } ?? "Trip Mode is off").font(.rounded(14, .semibold)); Spacer()
                        Text(active == nil ? "Turn on" : "Manage").font(.rounded(13, .bold)).foregroundStyle(Theme.accent); Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                        .padding(12).background(active == nil ? Theme.segBg : Theme.greenBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain)
                SegmentedTabs(options: [(Mode.trips, "By trip"), (Mode.spending, "By spending")], selection: $mode)
                if mode == .trips {
                    if summary.trips.isEmpty {
                        EmptyCard("No trips yet", "Create one, turn on Trip Mode, and new charges tag themselves.") {
                            Button("Create a trip") { creating = true }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        ForEach(summary.trips) { row in
                            NavigationLink(value: Route.trip(row.trip)) {
                                HStack(spacing: 14) {
                                    Text(row.trip.emoji ?? "🧳").font(.system(size: 30)).frame(width: 64, height: 64).background(row.trip.banner, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) { Text(row.trip.name).font(.rounded(16, .bold)); if row.trip.isActive { MiniChip(text: "on", style: .good) } }
                                        Text(row.trip.dateRange).font(.rounded(12)).foregroundStyle(Theme.muted)
                                        Text(Money.whole(row.spend)).font(.rounded(16, .bold))
                                    }
                                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.mutedLine)
                                }.card(padding: 12)
                            }.buttonStyle(.plain)
                        }
                    }
                } else if summary.categories.isEmpty {
                    EmptyCard("Nothing to group yet", "Once trips have spending, it’s grouped by category here.")
                } else {
                    VStack(spacing: 14) {
                        ForEach(Array(summary.categories.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                IconTile(symbol: row.category?.icon ?? "?", color: row.category.map { Color(hex: $0.effectiveColorHex) } ?? Theme.miscColor, size: 34)
                                VStack(spacing: 6) {
                                    HStack { Text(row.category?.name ?? "Unsorted").font(.rounded(15, .semibold)); Spacer(); Text(Money.whole(row.spend)).font(.rounded(15, .bold)) }
                                    ProgressView(value: row.spend, total: peak).tint(row.category.map { Color(hex: $0.effectiveColorHex) } ?? Theme.miscColor)
                                }
                            }
                        }
                    }.card()
                }
                Text("Same expenses, two ways of grouping them. Nothing is counted twice.").font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") } } }
        }
        .navigationTitle("Travel").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $creating) { TripEditSheet() }
    }
}

// MARK: - Trip detail

struct TripDetailView: View {
    let trip: Trip
    enum Tab { case overview, transactions }
    @State private var tab = Tab.overview
    @State private var editing = false

    var body: some View {
        WithLedger { ledger in
            let detail = ledger.tripDetail(trip)
            let peak = max(1, detail.tree.roots.map(\.totalSGD).max() ?? 1)
            Screen {
                HStack(spacing: 14) {
                    Text(trip.emoji ?? "🧳").font(.system(size: 44))
                    VStack(alignment: .leading) { Text(trip.name).font(.rounded(22, .bold)); Text(trip.dateRange).font(.rounded(13)) }
                    Spacer()
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.25), radius: 6, y: 1).padding(22)
                    .background(trip.banner, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                SegmentedTabs(options: [(Tab.overview, "Overview"), (Tab.transactions, "Transactions")], selection: $tab)
                if tab == .overview {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) { Text(Money.string(detail.summary.spend)).font(.rounded(22, .heavy)); Text("Your spending").font(.rounded(12)).foregroundStyle(Theme.muted) }
                            .frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.blueBg, bordered: false)
                        VStack(alignment: .leading, spacing: 2) { Text(Money.string(detail.fronted)).font(.rounded(22, .heavy)); Text("You fronted for others").font(.rounded(12)).foregroundStyle(Theme.muted) }
                            .frame(maxWidth: .infinity, alignment: .leading).card(background: Theme.orangeBg, bordered: false)
                    }
                    let categories = detail.tree.roots.filter { $0.totalSGD > 0 }
                    if categories.isEmpty {
                        EmptyCard("No spending on this trip yet", trip.isActive ? "Trip Mode is on, so new charges will land here." : "Turn on Trip Mode and new charges land here automatically.")
                    } else {
                        Rows {
                            ForEach(categories) { node in
                                NavigationLink(value: Route.category(CategoryTarget(category: node.category, unsortedOf: nil, scope: .trip(trip)))) {
                                    HStack(spacing: 12) {
                                        IconTile(symbol: node.icon, color: Color(hex: node.colorHex), size: 34)
                                        VStack(spacing: 6) {
                                            HStack { Text(node.name).font(.rounded(15, .semibold)); Spacer(); Text(Money.whole(node.totalSGD)).font(.rounded(15, .bold)) }
                                            ProgressView(value: node.totalSGD, total: peak).tint(Color(hex: node.colorHex))
                                        }
                                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedLine)
                                    }.padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
                                }.buttonStyle(.plain)
                            }
                            if detail.tree.unsortedSGD > 0 {
                                NavigationLink(value: Route.category(CategoryTarget(category: nil, unsortedOf: nil, scope: .trip(trip)))) {
                                    MenuRow("Unsorted") { Text(Money.whole(detail.tree.unsortedSGD)).font(.rounded(15, .bold)) }
                                }.buttonStyle(.plain)
                            }
                        }.flushCard()
                    }
                    Text("Who owes what is tracked on the Reimburse tab, not per trip.").font(.rounded(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                    NavigationLink(value: Route.tripMode) { Text(trip.isActive ? "Manage Trip Mode" : "Turn on Trip Mode for this trip").font(.rounded(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12) }
                        .buttonStyle(.bordered)
                } else if detail.entries.isEmpty { EmptyCard("No transactions on this trip yet") }
                else { GroupedFeed(entries: detail.entries) }
            }
        }
        .navigationTitle(trip.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { editing = true } label: { Image(systemName: "pencil") } } }
        .sheet(isPresented: $editing) { TripEditSheet(trip: trip) }
    }
}

// MARK: - Trip Mode

struct TripModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var chosenID: PersistentIdentifier?
    @State private var creating = false
    @State private var editing: Trip?

    var body: some View {
        WithLedger { ledger in
            let sorted = ledger.tripSummaries().map(\.trip)
            let chosen = sorted.first { $0.persistentModelID == chosenID } ?? ledger.activeTrip ?? sorted.first
            Screen {
                if let chosen {
                    let isOn = chosen.isActive
                    HStack {
                        Text("Automatically tag new transactions with this trip").font(.rounded(14)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Toggle("Trip Mode", isOn: Binding(get: { isOn }, set: { on in
                            Actions.setActive(on ? chosen : nil, in: context)
                            toaster.show(on ? "Trip Mode is on for \(chosen.name)" : "Trip Mode is off")
                        })).labelsHidden().tint(Theme.good)
                    }.card()
                    NavigationLink(value: Route.trip(chosen)) {
                        HStack(spacing: 14) {
                            Text(chosen.emoji ?? "🧳").font(.system(size: 40))
                            VStack(alignment: .leading) { Text(chosen.name).font(.rounded(20, .bold)); Text(chosen.dateRange).font(.rounded(13)) }
                            Spacer()
                        }.foregroundStyle(.white).padding(22).background(chosen.banner, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }.buttonStyle(.plain)
                    if sorted.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(sorted) { t in
                                Button { chosenID = t.persistentModelID } label: {
                                    Text("\(t.emoji ?? "🧳") \(t.name)").font(.rounded(13, .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                                        .foregroundStyle(t.persistentModelID == chosen.persistentModelID ? .white : Theme.muted)
                                        .background(t.persistentModelID == chosen.persistentModelID ? Theme.accent : Theme.surface, in: Capsule()).overlay { Capsule().stroke(Theme.line) }
                                }
                            } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isOn ? "✅ Trip Mode is ON" : "Trip Mode is OFF").font(.rounded(16, .bold))
                        Text(isOn ? "New transactions will be tagged with “\(chosen.name)”. You can untag ones that don’t belong, like rent."
                                  : (ledger.activeTrip.map { "Trip Mode is on for “\($0.name)”. Turning it on here switches it over." } ?? "Turn it on and new transactions tag themselves with this trip."))
                            .font(.rounded(13))
                    }.frame(maxWidth: .infinity, alignment: .leading).card(background: isOn ? Theme.greenBg : Theme.surface)
                    Button { editing = chosen } label: { MenuRow("Trip settings") { Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.muted) } }.buttonStyle(.plain).flushCard()
                    suggested(ledger, chosen)
                    NavigationLink(value: Route.categories) { MenuRow("Customise categories") }.buttonStyle(.plain).flushCard()
                } else {
                    VStack(spacing: 12) {
                        Text("🧳").font(.system(size: 44))
                        Text("Set up before a trip").font(.rounded(18, .bold))
                        Text("Create a trip and turn on Trip Mode. Every new transaction is tagged with it automatically, and you can untag anything unrelated, like rent.")
                            .font(.rounded(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        Button("Create a trip") { creating = true }.buttonStyle(.borderedProminent)
                    }.card(padding: 28)
                }
            }
        }
        .navigationTitle("Trip Mode").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $creating) { TripEditSheet() }
        .sheet(item: $editing) { TripEditSheet(trip: $0) }
    }

    private func suggested(_ ledger: Ledger, _ trip: Trip) -> some View {
        let names = ["Food", "Transport", "Accommodation", "Activities", "Shopping", "Souvenirs"]
        let cats = names.compactMap { n in ledger.topLevel.first { $0.name == n } }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Suggested categories").font(.rounded(15, .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                ForEach(cats) { c in
                    NavigationLink(value: Route.category(CategoryTarget(category: c, unsortedOf: nil, scope: .trip(trip)))) {
                        VStack(spacing: 6) { IconTile(symbol: c.icon, color: Color(hex: c.effectiveColorHex), size: 44); Text(c.name).font(.rounded(12)).foregroundStyle(Theme.text) }
                    }.buttonStyle(.plain)
                }
            }
            Text("Tap one to see what this trip spent there. Your own categories work as usual.").font(.rounded(12)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

// MARK: - Reimbursements

struct ReimburseView: View {
    enum Tab { case owed, history }
    @Environment(\.modelContext) private var context
    @State private var tab = Tab.owed
    @State private var showAll = false

    var body: some View {
        WithLedger { ledger in
            let data = ledger.reimbursementSummary()
            Screen {
                SegmentedTabs(options: [(Tab.owed, "Owed back to you"), (Tab.history, "History")], selection: $tab)
                if tab == .owed { owed(data) } else { history(data) }
            }
            .onAppear { Actions.recordCheckpointIfNeeded(data, in: context) }
            .onChange(of: data.pendingCheckpoint != nil) { _, pending in if pending { Actions.recordCheckpointIfNeeded(data, in: context) } }
        }
        .navigationTitle("Reimbursement").navigationBarTitleDisplayMode(.inline)
    }

    private enum Line: Identifiable { case paid(PaidEntry), received(ReceivedEntry)
        var id: String { switch self { case .paid(let p): "p" + p.id; case .received(let r): "r" + r.id } }
        var date: Date { switch self { case .paid(let p): p.date ?? .distantPast; case .received(let r): r.date ?? .distantPast } } }

    @ViewBuilder
    private func owed(_ data: ReimbursementData) -> some View {
        let lines = (data.recentPaid.map(Line.paid) + data.recentReceived.map(Line.received)).sorted { $0.date > $1.date }
        let shown = showAll ? lines : Array(lines.prefix(5))
        VStack(spacing: 8) {
            if data.overReimbursed {
                Text(Money.whole(-data.outstanding)).font(.rounded(42, .heavy))
                Text("received beyond what you were owed").foregroundStyle(Theme.muted)
                Text("Open the reimbursement that pushed it over and tell the app how to treat the extra, or that earlier records were incomplete.").font(.rounded(13)).multilineTextAlignment(.center)
            } else if data.settled || data.outstanding <= 0.005 {
                Text("🎉").font(.system(size: 40))
                Text("All settled").font(.rounded(30, .heavy))
                Text(data.receivedTotal > 0 ? "\(Money.whole(data.receivedTotal)) paid back so far" : "Nobody owes you anything").foregroundStyle(Theme.muted)
            } else {
                Text(Money.whole(data.outstanding)).font(.rounded(42, .heavy))
                Text("owed back to you").foregroundStyle(Theme.muted)
                if !data.recentPaid.isEmpty {
                    Text(data.lastCheckpoint.map { "Since everything was last settled on \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? "Across everything you’ve fronted so far").font(.rounded(12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(22).background(data.settled ? Theme.greenBg : (data.overReimbursed ? Theme.orangeBg : Theme.warmBg), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        SectionTitle("Recent activity") {
            if lines.count > 5 { Button(showAll ? "Show fewer" : "See all") { showAll.toggle() }.font(.rounded(13, .semibold)) }
        }
        if shown.isEmpty { Text("Nothing paid for others yet. Open a transaction and use “Split / Paid for others”.").font(.rounded(13)).foregroundStyle(Theme.muted) }
        else { Rows { ForEach(shown) { line in activityRow(line) } }.flushCard() }
        HStack(alignment: .top, spacing: 10) {
            Text("💡"); VStack(alignment: .leading, spacing: 2) { Text("Tip").font(.rounded(14, .bold))
                Text("When money arrives from a friend, open it and mark it as a reimbursement. That lowers what you’re owed without touching your spending.").font(.rounded(13)) }
        }.card(background: Theme.orangeBg, bordered: false)
    }

    @ViewBuilder
    private func activityRow(_ line: Line) -> some View {
        switch line {
        case .paid(let p):
            let body = HStack(spacing: 12) {
                Text("−" + Money.whole(p.othersSGD)).font(.rounded(13, .bold)).foregroundStyle(Theme.bad).padding(.horizontal, 9).padding(.vertical, 5).background(Theme.bad.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text([p.merchant == "No receipt yet" ? p.name : p.merchant ?? p.name, p.tripName].compactMap { $0 }.joined(separator: " · ")).font(.rounded(15, .semibold)).lineLimit(1)
                    Text("Paid for others").font(.rounded(12)).foregroundStyle(Theme.muted)
                }
                Spacer(); Text(p.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.rounded(12)).foregroundStyle(Theme.muted)
                if p.transaction != nil { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedLine) }
            }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle()).rowDivider()
            if let t = p.transaction { NavigationLink(value: Route.transaction(t)) { body }.buttonStyle(.plain) } else { body }
        case .received(let r):
            NavigationLink(value: Route.transaction(r.transaction)) {
                HStack(spacing: 12) {
                    Text(Money.string(r.amount, sign: true).replacingOccurrences(of: ".00", with: "")).font(.rounded(13, .bold)).foregroundStyle(Theme.good).padding(.horizontal, 9).padding(.vertical, 5).background(Theme.good.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) { Text(r.description).font(.rounded(15, .semibold)).lineLimit(1); Text("Reimbursement").font(.rounded(12)).foregroundStyle(Theme.muted) }
                    Spacer(); Text(r.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.rounded(12)).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedLine)
                }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle()).rowDivider()
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func history(_ data: ReimbursementData) -> some View {
        let earlier = (data.earlierPaid.map(Line.paid) + data.earlierReceived.map(Line.received)).sorted { $0.date > $1.date }
        let past = data.checkpoints
        if past.isEmpty { EmptyCard("No settled periods yet", "Each time your balance returns to $0, it’s recorded here.") }
        else {
            Rows { ForEach(past) { c in
                HStack(spacing: 12) {
                    Circle().fill(Theme.good).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Settled \(c.reachedAt.formatted(.dateTime.day().month(.abbreviated).year()))").font(.rounded(15, .semibold))
                        Text("\(Money.whole(c.paidTotal)) fronted · \(Money.whole(c.receivedTotal)) received").font(.rounded(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
            } }.flushCard()
        }
        if !earlier.isEmpty { SectionTitle("Earlier activity"); Rows { ForEach(earlier) { activityRow($0) } }.flushCard() }
    }
}

