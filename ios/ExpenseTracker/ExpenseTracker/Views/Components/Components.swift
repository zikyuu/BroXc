import SwiftUI
import SwiftData

// MARK: - small pieces

struct IconTile: View {
    let symbol: String?
    var color: Color = Theme.miscColor
    var size: CGFloat = 40
    var body: some View {
        Text(symbol ?? "•")
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(color.opacity(0.28), in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }
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
    init(_ title: String, _ message: String? = nil, @ViewBuilder action: () -> Action) { self.title = title; self.message = message; self.action = action() }
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.rounded(16, .semibold)).multilineTextAlignment(.center)
            if let message { Text(message).font(.rounded(13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center) }
            action
        }
        .frame(maxWidth: .infinity)
        .card(padding: 24)
    }
}
extension EmptyCard where Action == EmptyView {
    init(_ title: String, _ message: String? = nil) { self.init(title, message) { EmptyView() } }
}

struct PrimaryButton: View {
    let title: String
    var disabled = false
    var tint: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.rounded(16, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                .foregroundStyle(.white)
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

    private static let incomingIcon: [TransactionType: String] = [.reimbursement: "🤝", .income: "💰", .refund: "↩️",
                                                                   .transferOwnAccount: "🔁", .other: "⬇️"]
    static let incomingLabel: [TransactionType: String] = [.reimbursement: "Reimbursement", .income: "Income",
                                                           .refund: "Refund", .transferOwnAccount: "Own account transfer", .other: "Money in"]

    private var subtitle: String {
        var parts: [String] = []
        if showDate, let date = entry.date { parts.append(date.formatted(.dateTime.day().month(.abbreviated))) }
        if entry.isIncoming { parts.append(entry.transaction?.incomeLabel ?? Self.incomingLabel[entry.type] ?? "Money in") }
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
            if entry.isIncoming { IconTile(symbol: Self.incomingIcon[entry.type] ?? "⬇️", color: Theme.good) }
            else {
                let cat = entry.category?.category
                IconTile(symbol: cat?.icon ?? (entry.kind == .receipt ? "🧾" : "•"), color: cat.map { Color(hex: $0.effectiveColorHex) } ?? Theme.miscColor)
                    .opacity(entry.category?.confidence == .suggested ? 0.45 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.rounded(15, .semibold)).lineLimit(1)
                Text(subtitle).font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1)
                if entry.trip != nil || entry.status == "needs_review" || entry.status == "unmatched" || entry.category?.confidence == .suggested {
                    HStack(spacing: 5) {
                        if let trip = entry.trip { MiniChip(text: trip.name, style: .trip) }
                        if entry.status == "needs_review" { MiniChip(text: "check match", style: .warn) }
                        if entry.status == "unmatched" { MiniChip(text: "no receipt", style: .quiet) }
                        if !entry.isIncoming, entry.category?.confidence == .suggested { MiniChip(text: "guessed", style: .quiet) }
                    }.lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.isIncoming ? Money.string(entry.amountSGD, sign: true) : Money.string(split ? entry.personalSGD : entry.amountSGD))
                    .font(.rounded(15, .semibold)).foregroundStyle(entry.isIncoming ? Theme.good : Theme.text)
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
    @ViewBuilder let content: (Ledger) -> Content
    var body: some View {
        content(Ledger(receipts: receipts, transactions: transactions, categories: categories, trips: trips,
                       reconciliations: reconciliations, checkpoints: checkpoints, rules: rules))
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
                Text(message).font(.rounded(14, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(toaster.isError ? Theme.bad : Color.black.opacity(0.85), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 6)
        .animation(.snappy, value: toaster.message)
        .allowsHitTesting(false)
    }
}
