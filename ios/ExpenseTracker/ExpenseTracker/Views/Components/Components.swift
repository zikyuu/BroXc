import SwiftUI
import SwiftData

// MARK: - small pieces

/// A category's picture: one of the hand-drawn icons (`asset:cat-meat`), or an emoji the user typed.
struct Glyph: View {
    let symbol: String?
    var size: CGFloat = 20
    var body: some View {
        if let symbol, symbol.hasPrefix("sf:") {
            Image(systemName: String(symbol.dropFirst(3))).font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.75))
        } else if let symbol, symbol.hasPrefix(CategoryArt.prefix) {
            let name = String(symbol.dropFirst(CategoryArt.prefix.count))
            if UIImage(named: name) != nil { Image(name).resizable().scaledToFit().frame(width: size * 1.15, height: size * 1.15) }
            else { Image(systemName: "questionmark.square.dashed").font(.system(size: size * 0.9)).foregroundStyle(Theme.muted) }   // an icon that hasn't been drawn yet
        } else {
            Text(symbol ?? "•").font(.system(size: size))
        }
    }
}

struct IconTile: View {
    let symbol: String?
    var color: Color = Theme.miscColor
    var size: CGFloat = 40
    var body: some View {
        Glyph(symbol: symbol, size: size * 0.5)
            .frame(width: size, height: size)
            .background(color.opacity(0.28), in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }
}

/// The picture for each kind of money movement, until each gets its own drawing (these are system symbols, not emoji).
enum Art {
    static let reimbursement = "sf:person.2.fill"
    static let income = "sf:banknote.fill"
    static let refund = "sf:arrow.uturn.backward.circle.fill"
    static let cashback = "sf:tag.fill"
    static let transfer = "sf:arrow.left.arrow.right.circle.fill"
    static let moneyIn = "sf:arrow.down.circle.fill"
    static let person = "sf:person.fill"
    static let receipt = "asset:cat-receipt"
    static let link = "sf:link"
    static let help = "sf:questionmark.circle.fill"
    static let categories = "sf:square.grid.2x2.fill"
    static let budget = "sf:chart.pie.fill"
    static let trip = "sf:suitcase.fill"
    static let tip = "sf:lightbulb.fill"
    static let pant = "asset:cat-pant"
    static let flights = "asset:cat-flights"
    static func type(_ t: TransactionType) -> String {
        switch t {
        case .reimbursement: reimbursement; case .income: income; case .refund: refund; case .cashback: cashback
        case .transferOwnAccount: transfer; case .other, .expense: moneyIn
        }
    }
}

/// The picture a trip uses: one of the drawn scenes. (Older trips stored an emoji here; those map to the nearest scene.)
enum TripArt {
    static let all: [(key: String, name: String)] = [
        ("trip-airport", "Flight"), ("trip-castle", "Old town"), ("trip-beach", "Beach"), ("trip-snow", "Snow"), ("trip-camping", "Camping"),
        ("trip-japan", "Japan"), ("trip-coast", "Coast"), ("trip-london", "London"), ("trip-amsterdam", "Canals"),
    ]
    static func key(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return "trip-castle" }
        if all.contains(where: { $0.key == stored }) { return stored }
        switch stored {   // covers chosen before the current set, and old emoji
        case "trip-plane", "trip-train", "✈️", "🛳️", "🚂": return "trip-airport"
        case "trip-mountains", "🏔️", "🌲": return "trip-camping"
        case "trip-city", "🌆": return "trip-london"
        case "trip-exploring", "🎌", "🎡": return "trip-japan"
        case "🏖️": return "trip-beach"
        default: return "trip-castle"
        }
    }
}

/// A trip's scene as a picture, cropped to fill whatever size it's given.
struct TripCover: View {
    let trip: Trip
    var radius: CGFloat = 14
    var body: some View {
        Color.clear.overlay { Image(TripArt.key(trip.emoji)).resizable().scaledToFill() }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line) }
    }
}

/// A trip's name with its little cover, for chips and rows.
struct TripName: View {
    let trip: Trip
    var body: some View {
        HStack(spacing: 6) { TripCover(trip: trip, radius: 5).frame(width: 18, height: 18); Text(trip.name) }
    }
}

/// The big trip header: the scene with the name over it.
struct TripBanner: View {
    let trip: Trip
    var height: CGFloat = 150
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.overlay { Image(TripArt.key(trip.emoji)).resizable().scaledToFill() }
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.rounded(22, .bold))
                Text(trip.dateRange).font(.rounded(13))
            }.foregroundStyle(.white).padding(16)
        }
        .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The BroXc mascot in one of its expressions (`thinking`, `happy`, `sad`, ...).
struct Mascot: View {
    let name: String
    var height: CGFloat = 80
    var body: some View { Image("mascot-\(name)").resizable().scaledToFit().frame(height: height).accessibilityHidden(true) }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.trailing = trailing() }
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.rounded(12, .bold)).tracking(0.5).foregroundStyle(Theme.muted)
            Spacer()
            trailing
        }
        .padding(.top, 6)
    }
}
extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

struct MiniChip: View {
    enum Style { case trip, paid, warn, quiet, good }
    let text: String
    var style: Style = .quiet
    var body: some View {
        Text(text)
            .font(.rounded(11, .semibold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }
    private var foreground: Color {
        switch style {
        case .trip: Theme.accent
        case .paid, .warn: Theme.orangeInk
        case .quiet: Theme.muted
        case .good: Theme.good
        }
    }
    private var background: Color {
        switch style {
        case .trip: Theme.blueBg
        case .paid, .warn: Theme.orangeBg
        case .quiet: Theme.segBg
        case .good: Theme.greenBg
        }
    }
}

/// A category as a small coloured pill. A dashed outline and "?" mean it's a guess, not confirmed.
struct CategoryChip: View {
    let category: Category?
    let confidence: CategoryConfidence
    var full = false
    var body: some View {
        let color = category.map { Color(hex: $0.effectiveColorHex) } ?? Theme.miscColor
        let label = category.map { full ? $0.path.joined(separator: " › ") : $0.name } ?? "Unsorted"
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).lineLimit(1)
            if confidence == .suggested { Text("?").fontWeight(.heavy) }
        }
        .font(.rounded(12, .medium))
        .foregroundStyle(category == nil ? Theme.muted : Theme.text)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(category == nil ? Color.clear : color.opacity(0.22), in: Capsule())
        .overlay { if confidence == .suggested || category == nil {
            Capsule().strokeBorder(category == nil ? Theme.mutedLine : color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } }
    }
}

struct SegmentedTabs<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { withAnimation(.snappy(duration: 0.2)) { selection = option.0 } } label: {
                    Text(option.1)
                        .font(.rounded(14, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(selection == option.0 ? Theme.accent : Theme.muted)
                        .background { if selection == option.0 {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface).shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.segBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EmptyCard<Action: View>: View {
    let title: String
    let message: String?
    let action: Action
    var mascot: String? = "expr-thinking"
    init(_ title: String, _ message: String? = nil, mascot: String? = "expr-thinking", @ViewBuilder action: () -> Action) { self.title = title; self.message = message; self.mascot = mascot; self.action = action() }
    var body: some View {
        VStack(spacing: 8) {
            if let mascot { Mascot(name: mascot, height: 64) }
            Text(title).font(.rounded(16, .semibold)).multilineTextAlignment(.center)
            if let message { Text(message).font(.rounded(13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center) }
            action
        }
        .frame(maxWidth: .infinity)
        .card(padding: 24)
    }
}
extension EmptyCard where Action == EmptyView {
    init(_ title: String, _ message: String? = nil, mascot: String? = "expr-thinking") { self.init(title, message, mascot: mascot) { EmptyView() } }
}

struct PrimaryButton: View {
    let title: String
    var disabled = false
    var tint: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.rounded(16, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                .foregroundStyle(Theme.onAccent)
                .background(tint.opacity(disabled ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(disabled)
    }
}

struct QuietButton: View {
    let title: String
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.rounded(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(danger ? Theme.bad : Theme.muted)
        }
    }
}

/// One row inside a flush card: label on the left, optional value, chevron when it navigates.
struct MenuRow<Trailing: View>: View {
    let label: String
    let hint: String?
    let chevron: Bool
    let trailing: Trailing
    init(_ label: String, hint: String? = nil, chevron: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.label = label; self.hint = hint; self.chevron = chevron; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.rounded(15))
                if let hint { Text(hint).font(.rounded(12)).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 8)
            trailing
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mutedLine) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .rowDivider()
    }
}
extension MenuRow where Trailing == EmptyView {
    init(_ label: String, hint: String? = nil, chevron: Bool = true) { self.init(label, hint: hint, chevron: chevron) { EmptyView() } }
}

struct Hairline: View { var body: some View { Rectangle().fill(Theme.line).frame(height: 1) } }

/// A vertical stack of rows; each row draws its own hairline on top (see `rowDivider`).
struct Rows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 0) { content } }
}

extension View {
    /// A hairline along the top of a row. The first row's sits against the card's own border, so it doesn't show.
    func rowDivider() -> some View { overlay(alignment: .top) { Hairline() } }
}

// MARK: - transaction row

struct TransactionRow: View {
    let entry: ActivityEntry
    var showDate = false

    private static let incomingIcon: [TransactionType: String] = [.reimbursement: Art.reimbursement, .income: Art.income, .refund: Art.refund, .cashback: Art.cashback,
                                                                   .transferOwnAccount: Art.transfer, .other: Art.moneyIn]
    static let incomingLabel: [TransactionType: String] = [.reimbursement: "Reimbursement", .income: "Income", .cashback: "Cashback",
                                                           .refund: "Refund", .transferOwnAccount: "Own account transfer", .other: "Money in"]

    private var subtitle: String {
        var parts: [String] = []
        if showDate, let date = entry.date { parts.append(date.formatted(.dateTime.day().month(.abbreviated))) }
        if entry.isIncoming { parts.append(entry.outflow && entry.type == .transferOwnAccount ? "Transfer out" : (entry.transaction?.incomeLabel ?? Self.incomingLabel[entry.type] ?? "Money in")) }
        else if let payee = entry.transaction?.payee { parts.append("Paid to \(payee)") }
        else if entry.status == "receipt_only" { parts.append("Receipt · no charge linked yet") }
        else if let c = entry.category, c.mixed { parts.append("\(c.distinct) categories") }
        else if let c = entry.category?.category {
            let path = c.path.suffix(2).joined(separator: " › ")
            parts.append(entry.category?.confidence == .suggested ? "Guess: \(path)" : path)
        }
        else { parts.append("Unsorted") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let split = entry.othersSGD > 0.005
        HStack(spacing: 12) {
            if entry.isIncoming { IconTile(symbol: Self.incomingIcon[entry.type] ?? Art.moneyIn, color: Theme.good) }
            else {
                let cat = entry.category?.category
                IconTile(symbol: cat?.icon ?? (entry.transaction?.payee != nil ? Art.person : Art.receipt), color: cat.map { Color(hex: $0.effectiveColorHex) } ?? Theme.miscColor)
                    .opacity(entry.category?.confidence == .suggested ? 0.45 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.rounded(15, .semibold)).lineLimit(1)
                Text(subtitle).font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1)
                if entry.trip != nil || entry.status == "needs_review" || entry.status == "unmatched" || entry.category?.confidence == .suggested || entry.matchedReceipt?.unexplainedAmount != nil {
                    HStack(spacing: 5) {
                        if let trip = entry.trip { MiniChip(text: trip.name, style: .trip) }
                        if entry.status == "needs_review" { MiniChip(text: "check match", style: .warn) }
                        if entry.status == "unmatched" { MiniChip(text: entry.transaction?.payee != nil ? "not itemised" : "no receipt", style: .quiet) }
                        if entry.matchedReceipt?.unexplainedAmount != nil { MiniChip(text: "items don’t add up", style: .warn) }
                        if !entry.isIncoming, entry.category?.confidence == .suggested { MiniChip(text: "guessed", style: .quiet) }
                    }.lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.isIncoming ? (entry.outflow ? Money.string(-(entry.amountSGD ?? 0)) : Money.string(entry.amountSGD, sign: true)) : Money.string(split ? entry.personalSGD : entry.amountSGD))
                    .font(.rounded(15, .semibold)).foregroundStyle(entry.isIncoming ? (entry.outflow ? Theme.muted : Theme.good) : Theme.text)
                if split { Text("of \(Money.string(entry.amountSGD))").font(.rounded(11)).foregroundStyle(Theme.muted) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        .rowDivider()
    }
}

/// A date-grouped feed, one card per day.
struct GroupedFeed: View {
    let entries: [ActivityEntry]
    var body: some View {
        let days = Dictionary(grouping: entries) { $0.date?.startOfDay ?? .distantPast }.sorted { $0.key > $1.key }
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(days, id: \.key) { day, rows in
                Text(Self.heading(for: day)).font(.rounded(13, .bold)).foregroundStyle(Theme.muted).padding(.leading, 4).padding(.top, 8)
                Rows {
                    ForEach(rows) { entry in
                        NavigationLink(value: entry.transaction != nil ? Route.transaction(entry.transaction!) : Route.receipt(entry.receipt!)) {
                            TransactionRow(entry: entry)
                        }.buttonStyle(.plain)
                    }
                }.flushCard()
            }
        }
    }

    static func heading(for day: Date) -> String {
        if day == .distantPast { return "No date" }
        let diff = Dates.calendar.dateComponents([.day], from: day, to: Date().startOfDay).day ?? 0
        if diff == 0 { return "Today" }
        if diff == 1 { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - navigation

struct CategoryTarget: Hashable {
    enum Scope: Hashable { case month(MonthKey), trip(Trip) }
    /// A real category, or nil for the top-level "Unsorted" bucket.
    var category: Category?
    /// Set for the synthetic "Unsorted in X" bucket: X's loose items.
    var unsortedOf: Category?
    var scope: Scope
}

enum Route: Hashable {
    case category(CategoryTarget)
    case transaction(YouTripTransaction)
    case receipt(Receipt)
    case split(YouTripTransaction)
    case classify(YouTripTransaction)
    case breakdown(YouTripTransaction)
    case trip(Trip)
    case tripMode
    case search, trends, review, balance, categories, add, more
    case account(Account)
    case accounts
    case help
    case reimbursementLog(Trip)
    case budgets
}

/// Reads everything the engine needs and hands screens a fresh `Ledger`. SwiftData re-renders this when
/// anything underneath it changes, so every screen stays live without any manual refreshing.
struct WithLedger<Content: View>: View {
    @Query private var receipts: [Receipt]
    @Query private var transactions: [YouTripTransaction]
    @Query private var categories: [Category]
    @Query private var trips: [Trip]
    @Query private var reconciliations: [BalanceReconciliation]
    @Query private var checkpoints: [BalanceCheckpoint]
    @Query private var rules: [ItemRule]
    @Query private var accounts: [BankAccount]
    @Query private var sharedCosts: [SharedCost]
    @AppStorage("totalBudget") private var totalBudget = 0.0
    @ViewBuilder let content: (Ledger) -> Content
    var body: some View {
        content(Ledger(receipts: receipts, transactions: transactions, categories: categories, trips: trips,
                       reconciliations: reconciliations, checkpoints: checkpoints, rules: rules, accounts: accounts, sharedCosts: sharedCosts, totalBudget: totalBudget))
    }
}

/// Screen shell: scrolling content on the warm background.
struct Screen<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
    }
}

/// A brief message at the top of the screen, for "Moved 2 items to Meat"-style feedback.
/// "Recategorised to Meat" / "3 items recategorised to Meat".
func recategorisedMessage(_ count: Int, to name: String?) -> String {
    count == 1 ? "Recategorised to \(name ?? "Unsorted")" : "\(count) items recategorised to \(name ?? "Unsorted")"
}

@MainActor @Observable
final class Toaster {
    var message: String?
    var isError = false
    private var task: Task<Void, Never>?
    func show(_ text: String, error: Bool = false) {
        message = text; isError = error
        task?.cancel()
        task = Task { try? await Task.sleep(for: .seconds(error ? 4 : 2.4)); if !Task.isCancelled { message = nil } }
    }
}

struct ToastOverlay: View {
    @Environment(Toaster.self) private var toaster
    var body: some View {
        VStack {
            if let message = toaster.message {
                Text(message).font(.rounded(12, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(toaster.isError ? Theme.bad.opacity(0.9) : Color.black.opacity(0.55), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 6)
        .animation(.snappy, value: toaster.message)
        .allowsHitTesting(false)
    }
}
