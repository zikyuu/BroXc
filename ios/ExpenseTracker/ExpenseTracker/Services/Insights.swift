import Foundation
import SwiftData

// MARK: - Result types

struct CategoryNode: Identifiable {
    let category: Category?          // nil for the synthetic "Unsorted" child
    let unsortedOf: Category?        // for that synthetic child: the category whose loose items it holds
    let name: String
    let icon: String
    let kind: CategoryKind
    let isUnsorted: Bool
    let colorHex: String
    let budget: Double?
    let ownSGD: Double
    let totalSGD: Double
    let count: Int
    let children: [CategoryNode]

    var id: String {
        if let category { return "c\(category.persistentModelID.hashValue)" }
        return "u\(unsortedOf?.persistentModelID.hashValue ?? 0)"
    }
}

struct CategoryTree {
    let roots: [CategoryNode]
    let unsortedSGD: Double
    let unsortedCount: Int
    let totalSGD: Double
    let unconverted: [String: Double]

    func node(for category: Category) -> CategoryNode? {
        func search(_ nodes: [CategoryNode]) -> CategoryNode? {
            for node in nodes {
                if node.category?.persistentModelID == category.persistentModelID { return node }
                if let hit = search(node.children) { return hit }
            }
            return nil
        }
        return search(roots)
    }
}

struct EntryCategory {
    let category: Category?
    let confidence: CategoryConfidence
    let mixed: Bool
    let distinct: Int
}

struct ActivityEntry: Identifiable {
    enum Kind { case transaction, receipt }
    let id: String
    let kind: Kind
    let date: Date?
    let title: String
    let amountSGD: Double?
    let localAmount: Double?
    let localCurrency: String?
    let type: TransactionType
    /// unmatched | needs_review | auto | approved | not_expense | receipt_only
    let status: String
    let trip: Trip?
    let note: String?
    let userNote: String?
    let transaction: YouTripTransaction?
    let receipt: Receipt?
    let personalSGD: Double
    let othersSGD: Double
    let itemCount: Int
    let category: EntryCategory?

    var isIncoming: Bool { type != .expense }
}

enum PaceStatus { case good, watch, over, neutral }

struct HomeCategory: Identifiable {
    let category: Category
    let actual: Double
    let budget: Double?
    let usual: Double?
    var id: String { "h\(category.persistentModelID.hashValue)" }
    var reference: Double? { budget ?? usual }
    var referenceIsBudget: Bool { budget != nil }
}

struct ComparedRow: Identifiable {
    let category: Category
    let delta: Double
    var id: String { "x\(category.persistentModelID.hashValue)" }
}

struct BalanceInfo {
    let implied: Double
    let reconciledOn: Date
    let reconciledAmount: Double
}

struct HomeData {
    let month: MonthKey
    let isCurrent: Bool
    let previous: MonthKey?
    let next: MonthKey?
    let hasData: Bool
    let dayLabel: String
    let elapsedFraction: Double
    let elapsedDays: Int
    let daysInMonth: Int
    let total: Double
    let categories: [HomeCategory]
    let unsorted: Double
    let untracked: Double
    let status: PaceStatus
    let projected: Double
    let usualTotal: Double?
    let usualMonths: Int
    let balance: BalanceInfo?
    let owedBack: Double
    let paceActual: [Double]
    let paceUsual: [Double]
    let balanceAfter: Double?
    let uncertain: Double
    let confident: Double
    let suggestions: Int
    let unknown: Int
    let matchesToCheck: Int
    let compared: [ComparedRow]
    let recent: [ActivityEntry]
}

struct ReviewData {
    let items: [ItemView]
    let matches: [YouTripTransaction]
    let uncertain: Double
    let confident: Double
    let suggestions: Int
    let unknown: Int
}

struct PaidEntry: Identifiable {
    let id: String
    let name: String
    let date: Date?
    let merchant: String?
    let othersSGD: Double
    let transaction: YouTripTransaction?
    let tripName: String?
}

struct ReceivedEntry: Identifiable {
    let id: String
    let date: Date?
    let description: String
    let amount: Double
    let total: Double
    let transaction: YouTripTransaction
}

struct ReimbursementData {
    let paidTotal: Double
    let receivedTotal: Double
    let outstanding: Double
    let settled: Bool
    let overReimbursed: Bool
    let lastCheckpoint: Date?
    let recentPaid: [PaidEntry]
    let recentReceived: [ReceivedEntry]
    let earlierPaid: [PaidEntry]
    let earlierReceived: [ReceivedEntry]
    let checkpoints: [BalanceCheckpoint]
    /// Set when the balance is settled and no checkpoint covers exactly this state yet.
    let pendingCheckpoint: PendingCheckpoint?
}

struct PendingCheckpoint {
    let reachedAt: Date
    let paidTotal: Double
    let receivedTotal: Double
    let itemIDs: [String]
    let reimbursementIDs: [String]
}

struct SearchResults {
    let query: String
    let items: [ItemView]
    let transactions: [ActivityEntry]
    let receipts: [(receipt: Receipt, matched: Int)]
    let trips: [Trip]
}

struct TripSummary: Identifiable {
    let trip: Trip
    let spend: Double
    let itemCount: Int
    var id: String { "t\(trip.persistentModelID.hashValue)" }
}

struct TravelSummary {
    let trips: [TripSummary]
    let categories: [(category: Category?, spend: Double)]
    let total: Double
    let shareOfSpending: Double
}

struct TripDetail {
    let summary: TripSummary
    let fronted: Double
    let tree: CategoryTree
    let entries: [ActivityEntry]
}

struct MonthPoint: Identifiable { let month: MonthKey; let total: Double; var id: String { month.id } }
struct WeekdayPoint: Identifiable { let weekday: Int; let label: String; let average: Double; var id: Int { weekday } }
struct CategoryChange: Identifiable {
    let category: Category
    let actual: Double
    let delta: Double?
    var id: String { "g\(category.persistentModelID.hashValue)" }
}
struct RecurringRow: Identifiable { let name: String; let months: Int; let count: Int; let typical: Double; var id: String { name } }

struct TrendsData {
    let months: [MonthPoint]
    let usualMonthly: Double?
    let dailyActual: [Double]
    let dailyUsual: [Double]
    let daysInMonth: Int
    let todayDay: Int
    let thisMonth: Double
    let averageDaily: Double
    let weekdays: [WeekdayPoint]
    let changes: [CategoryChange]
    let recurring: [RecurringRow]
    let trips: [TripSummary]
}

// MARK: - Analysis

extension Ledger {
    static let usualMonths = 6
    static let minProjectionDay = 3
    static let watchRatio = 1.15

    private func monthKey(_ item: ItemView) -> MonthKey? { item.date.map(MonthKey.init) }

    // MARK: category tree

    func categoryTree(range: ClosedRange<Date>? = nil, trip: Trip? = nil) -> CategoryTree {
        var own: [PersistentIdentifier?: Double] = [:]
        var count: [PersistentIdentifier?: Int] = [:]
        var unconverted: [String: Double] = [:]
        for item in items(in: range, trip: trip) {
            guard let personal = item.personalSGD else { unconverted[item.currency ?? "?", default: 0] += item.personalPrice; continue }
            if personal == 0 { continue }  // paid entirely for someone else: not personal spend anywhere
            let key = item.category?.persistentModelID
            own[key, default: 0] += personal
            count[key, default: 0] += 1
        }

        func build(_ category: Category) -> CategoryNode {
            var children = category.children.map(build)
            children.sort {
                if ($0.kind == .misc) != ($1.kind == .misc) { return $1.kind == .misc }
                if $0.totalSGD != $1.totalSGD { return $0.totalSGD > $1.totalSGD }
                return ($0.category?.sortOrder ?? 0) < ($1.category?.sortOrder ?? 0)
            }
            let ownSGD = own[category.persistentModelID] ?? 0
            let total = ownSGD + children.reduce(0) { $0 + $1.totalSGD }
            let nodeCount = (count[category.persistentModelID] ?? 0) + children.reduce(0) { $0 + $1.count }
            if !children.isEmpty && ownSGD > 0 {
                // real items sitting directly on a category that has children: the app can't place them any deeper
                children.append(CategoryNode(category: nil, unsortedOf: category, name: "Unsorted", icon: "?", kind: .normal,
                                             isUnsorted: true, colorHex: category.effectiveColorHex, budget: nil,
                                             ownSGD: round2(ownSGD), totalSGD: round2(ownSGD),
                                             count: count[category.persistentModelID] ?? 0, children: []))
            }
            return CategoryNode(category: category, unsortedOf: nil, name: category.name, icon: category.icon ?? "•",
                                kind: category.kind, isUnsorted: false, colorHex: category.effectiveColorHex,
                                budget: category.budgetSGD, ownSGD: round2(ownSGD), totalSGD: round2(total),
                                count: nodeCount, children: children)
        }
        let roots = topLevel.map(build)
        let loose = own[nil] ?? 0
        return CategoryTree(roots: roots, unsortedSGD: round2(loose), unsortedCount: count[nil] ?? 0,
                            totalSGD: round2(roots.reduce(0) { $0 + $1.totalSGD } + loose),
                            unconverted: unconverted.mapValues(round2))
    }

    // MARK: usual spending

    struct Usual {
        let months: Int
        let byRoot: [PersistentIdentifier?: Double]
        let total: Double?
        let cumulative: [Double]
    }

    func usual(before month: MonthKey) -> Usual {
        var perMonth: [MonthKey: [PersistentIdentifier?: Double]] = [:]
        var perMonthDays: [MonthKey: [Int: Double]] = [:]
        for item in counted {
            guard let key = monthKey(item), key < month, let date = item.date, let amount = item.personalSGD else { continue }
            perMonth[key, default: [:]][item.rootCategoryID, default: 0] += amount
            perMonthDays[key, default: [:]][date.dayOfMonth, default: 0] += amount
        }
        let months = Array(perMonth.keys.sorted().suffix(Self.usualMonths))
        guard !months.isEmpty else { return Usual(months: 0, byRoot: [:], total: nil, cumulative: []) }
        var roots = Set<PersistentIdentifier?>()
        for m in months { roots.formUnion(perMonth[m]!.keys) }
        let byRoot = Dictionary(uniqueKeysWithValues: roots.map { root in
            (root, months.reduce(0) { $0 + (perMonth[$1]?[root] ?? 0) } / Double(months.count))
        })
        let cumulative = (1...month.daysInMonth).map { day -> Double in
            let values = months.map { m in perMonthDays[m, default: [:]].filter { $0.key <= day }.values.reduce(0, +) }
            return round2(values.reduce(0, +) / Double(values.count))
        }
        return Usual(months: months.count, byRoot: byRoot, total: byRoot.values.reduce(0, +), cumulative: cumulative)
    }

    func cumulative(month: MonthKey, throughDay: Int) -> [Double] {
        var daily = [Double](repeating: 0, count: month.daysInMonth)
        for item in counted where monthKey(item) == month {
            daily[item.date!.dayOfMonth - 1] += item.personalSGD!
        }
        var running = 0.0
        return (0..<min(throughDay, daily.count)).map { running += daily[$0]; return round2(running) }
    }

    private func elapsed(_ month: MonthKey, today: Date) -> (fraction: Double, days: Int) {
        let day = today.startOfDay
        if day < month.firstDay { return (0, 0) }
        if day >= month.lastDay { return (1, month.daysInMonth) }
        return (Double(day.dayOfMonth) / Double(month.daysInMonth), day.dayOfMonth)
    }

    // MARK: balance

    func movement(since cutoff: Date?) -> Double {
        transactions.reduce(0) { sum, t in
            if let cutoff, t.createdAt <= cutoff { return sum }
            let amount = abs(t.amountSGD ?? 0)
            return sum + (t.transactionType == .expense ? -amount : amount)
        }
    }

    var latestReconciliation: BalanceReconciliation? { reconciliations.max { $0.createdAt < $1.createdAt } }

    var currentBalance: BalanceInfo? {
        guard let last = latestReconciliation else { return nil }
        return BalanceInfo(implied: round2(last.actualSGD + movement(since: last.knownThrough)),
                           reconciledOn: last.reconciledOn, reconciledAmount: last.actualSGD)
    }

    /// Missing money found by balance checks dated in this month. Extra money (a negative gap) isn't spending.
    func untracked(in month: MonthKey) -> Double {
        reconciliations.filter { MonthKey($0.reconciledOn) == month && $0.untrackedSGD > 0 }.reduce(0) { $0 + $1.untrackedSGD }
    }

    // MARK: bottle deposit

    /// Deposit paid at the till vs. credited back for returned bottles (a negative deposit line), in SGD.
    static func pantSummary(_ items: [ItemView]) -> (paid: Double, returned: Double, net: Double) {
        let deposits = items.filter(\.isDeposit).compactMap(\.priceSGD)
        let paid = round2(deposits.filter { $0 > 0 }.reduce(0, +))
        let returned = round2(-deposits.filter { $0 < 0 }.reduce(0, +))
        return (paid, returned, round2(paid - returned))
    }

    // MARK: activity

    private func entryCategory(_ group: [ItemView]) -> EntryCategory? {
        let real = group
        guard let top = real.max(by: { abs($0.priceSGD ?? 0) < abs($1.priceSGD ?? 0) }) else { return nil }
        let distinct = Set(real.map { $0.category?.persistentModelID })
        return EntryCategory(category: top.category, confidence: top.confidence, mixed: distinct.count > 1, distinct: distinct.count)
    }

    func activityFeed(limit: Int? = nil) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        for t in transactions {
            let group = items(of: t)
            let real = group
            let status: String
            if t.transactionType != .expense { status = "not_expense" } else { status = t.status }
            entries.append(ActivityEntry(
                id: "t-" + t.uid, kind: .transaction, date: t.date, title: t.transactionDescription ?? "Unknown charge",
                amountSGD: t.amountSGD, localAmount: t.localAmount, localCurrency: t.localCurrency,
                type: t.transactionType, status: status, trip: t.trip, note: t.matchNote, userNote: t.userNote,
                transaction: t, receipt: t.matchedReceipt,
                personalSGD: round2(real.reduce(0) { $0 + ($1.personalSGD ?? 0) }),
                othersSGD: round2(real.reduce(0) { $0 + ($1.othersSGD ?? 0) }),
                itemCount: real.count, category: entryCategory(group)))
        }
        let matched = Set(transactions.compactMap { $0.matchedReceipt?.persistentModelID })
        for receipt in receipts where !matched.contains(receipt.persistentModelID) {
            let group = items(of: receipt)
            let real = group
            guard !real.isEmpty else { continue }
            let known = real.allSatisfy { $0.priceSGD != nil }
            entries.append(ActivityEntry(
                id: "r-\(receipt.persistentModelID.hashValue)", kind: .receipt, date: receipt.date,
                title: receipt.merchant ?? "Receipt", amountSGD: known ? round2(real.reduce(0) { $0 + ($1.priceSGD ?? 0) }) : nil,
                localAmount: nil, localCurrency: nil, type: .expense, status: "receipt_only", trip: receipt.trip,
                note: nil, userNote: nil, transaction: nil, receipt: receipt,
                personalSGD: round2(real.reduce(0) { $0 + ($1.personalSGD ?? 0) }),
                othersSGD: round2(real.reduce(0) { $0 + ($1.othersSGD ?? 0) }),
                itemCount: real.count, category: entryCategory(group)))
        }
        entries.sort { ($0.date ?? .distantPast, $0.transaction?.createdAt ?? .distantPast) > ($1.date ?? .distantPast, $1.transaction?.createdAt ?? .distantPast) }
        return limit.map { Array(entries.prefix($0)) } ?? entries
    }

    // MARK: review

    func review(month: MonthKey? = nil) -> ReviewData {
        let pool = month == nil ? items : items.filter { monthKey($0) == month }
        let uncertain = pool
            .filter { !$0.isDeposit && ($0.personalSGD ?? 0) > 0 && $0.confidence != .confirmed }
            .sorted { ($0.personalSGD ?? 0) > ($1.personalSGD ?? 0) }
        let confident = pool.filter { !$0.isDeposit && $0.confidence == .confirmed }.reduce(0) { $0 + ($1.personalSGD ?? 0) }
        return ReviewData(
            items: uncertain,
            matches: transactions.filter { $0.transactionType == .expense && $0.matchedReceipt != nil && $0.status == "needs_review" },
            uncertain: round2(uncertain.reduce(0) { $0 + ($1.personalSGD ?? 0) }), confident: round2(confident),
            suggestions: uncertain.filter { $0.confidence == .suggested }.count,
            unknown: uncertain.filter { $0.confidence == .unknown }.count)
    }

    /// The one-line reconciliation picture, for the Activity header.
    var unmatchedCharges: [YouTripTransaction] { transactions.filter { $0.status == "unmatched" } }
    var unmatchedReceipts: [Receipt] {
        let matched = Set(transactions.compactMap { $0.matchedReceipt?.persistentModelID })
        return receipts.filter { !matched.contains($0.persistentModelID) }
    }

    // MARK: home

    func home(month requested: MonthKey? = nil, today: Date = Date()) -> HomeData {
        let current = MonthKey(today)
        let month = requested ?? current
        let usual = usual(before: month)
        let (fraction, elapsedDays) = elapsed(month, today: today)
        let monthItems = counted.filter { monthKey($0) == month && ($0.personalSGD ?? 0) > 0 }

        var actual: [PersistentIdentifier?: Double] = [:]
        for item in monthItems { actual[item.rootCategoryID, default: 0] += item.personalSGD ?? 0 }

        var rows: [HomeCategory] = []
        for root in topLevel {
            let spent = actual[root.persistentModelID] ?? 0
            let usualSGD = usual.byRoot[root.persistentModelID]
            if spent <= 0 && !((usualSGD ?? 0) > 0) { continue }
            rows.append(HomeCategory(category: root, actual: round2(spent), budget: root.budgetSGD, usual: usualSGD.map(round2)))
        }

        let unsorted = actual[nil] ?? 0
        let untracked = untracked(in: month)
        let total = actual.values.reduce(0, +) + untracked

        let projected: Double
        if fraction >= 1 { projected = total }
        else if fraction <= 0 { projected = 0 }
        else if elapsedDays >= Self.minProjectionDay { projected = total / fraction }
        else { projected = max(total, usual.total ?? total) }

        let budgets = rows.compactMap { $0.budget }
        let referenceTotal = usual.total ?? (budgets.isEmpty ? nil : budgets.reduce(0, +))
        var status = PaceStatus.neutral
        if let referenceTotal, referenceTotal > 0, projected > 0 {
            let ratio = projected / referenceTotal
            status = ratio <= 1 ? .good : (ratio <= Self.watchRatio ? .watch : .over)
        }

        var paceActual = fraction > 0 ? cumulative(month: month, throughDay: elapsedDays) : []
        if untracked > 0 { paceActual = paceActual.map { round2($0 + untracked) } }

        var compared: [ComparedRow] = []
        if usual.months > 0 && fraction > 0 {
            for root in topLevel {
                let expected = (usual.byRoot[root.persistentModelID] ?? 0) * fraction
                let delta = (actual[root.persistentModelID] ?? 0) - expected
                if abs(delta) >= 1 { compared.append(ComparedRow(category: root, delta: round2(delta))) }
            }
            compared.sort { abs($0.delta) > abs($1.delta) }
        }

        let uncertain = monthItems.filter { $0.confidence != .confirmed }
        let uncertainSGD = uncertain.reduce(0) { $0 + ($1.personalSGD ?? 0) }
        let balance = currentBalance
        let reimbursement = reimbursementSummary()
        let firstMonth = counted.compactMap(monthKey).min()
        let f = DateFormatter(); f.dateFormat = "d MMM"

        return HomeData(
            month: month, isCurrent: month == current,
            previous: (firstMonth != nil && firstMonth! < month) ? month.shifted(by: -1) : nil,
            next: month < current ? month.shifted(by: 1) : nil,
            hasData: !items.isEmpty || !transactions.isEmpty,
            dayLabel: month == current ? f.string(from: today) : month.label,
            elapsedFraction: fraction, elapsedDays: elapsedDays, daysInMonth: month.daysInMonth,
            total: round2(total), categories: rows, unsorted: round2(unsorted), untracked: round2(untracked),
            status: status, projected: round2(projected), usualTotal: usual.total.map(round2), usualMonths: usual.months,
            balance: balance, owedBack: max(0, reimbursement.outstanding),
            paceActual: paceActual, paceUsual: usual.cumulative,
            balanceAfter: (balance != nil && fraction < 1) ? round2(balance!.implied - max(0, projected - total)) : nil,
            uncertain: round2(uncertainSGD), confident: round2(monthItems.reduce(0) { $0 + ($1.personalSGD ?? 0) } - uncertainSGD),
            suggestions: uncertain.filter { $0.confidence == .suggested }.count,
            unknown: uncertain.filter { $0.confidence == .unknown }.count,
            matchesToCheck: review().matches.count,
            compared: Array(compared.prefix(4)), recent: activityFeed(limit: 5))
    }

    // MARK: reimbursements

    func reimbursementSummary() -> ReimbursementData {
        let paid = items.filter { !$0.isDeposit && ($0.othersSGD ?? 0) > 0 }.map {
            PaidEntry(id: $0.id, name: $0.name, date: $0.date, merchant: $0.merchant, othersSGD: $0.othersSGD ?? 0,
                      transaction: $0.transaction, tripName: $0.trip?.name)
        }
        let received = transactions.filter { $0.transactionType == .reimbursement }.map { t -> ReceivedEntry in
            let total = abs(t.amountSGD ?? 0)
            return ReceivedEntry(id: t.uid, date: t.date, description: t.transactionDescription ?? "Payment received",
                                 amount: abs(t.reimbursementAmount ?? total), total: total, transaction: t)
        }
        let paidTotal = round2(paid.reduce(0) { $0 + $1.othersSGD })
        let receivedTotal = round2(received.reduce(0) { $0 + $1.amount })
        let outstanding = round2(paidTotal - receivedTotal)
        let settled = abs(outstanding) < Self.balanceTolerance && (paidTotal > 0 || receivedTotal > 0)

        let last = checkpoints.max { $0.recordedAt < $1.recordedAt }
        let paidIDs = Set(paid.map(\.id)), receivedIDs = Set(received.map(\.id))
        var pending: PendingCheckpoint?
        var covered = last
        if settled && !(last != nil && Set(last!.coveredItemIDs) == paidIDs && Set(last!.coveredReimbursementIDs) == receivedIDs) {
            let dates = paid.compactMap(\.date) + received.compactMap(\.date)
            pending = PendingCheckpoint(reachedAt: dates.max() ?? Date(), paidTotal: paidTotal, receivedTotal: receivedTotal,
                                        itemIDs: Array(paidIDs), reimbursementIDs: Array(receivedIDs))
            covered = nil  // the not-yet-written checkpoint covers everything, so nothing is "recent"
        }
        // "since" the checkpoint is whatever it didn't cover - not judged by date, since spending gets
        // entered late and a back-dated item is still new information
        let coveredItems = pending != nil ? paidIDs : Set(covered?.coveredItemIDs ?? [])
        let coveredReceived = pending != nil ? receivedIDs : Set(covered?.coveredReimbursementIDs ?? [])
        func order<T>(_ list: [T], date: (T) -> Date?) -> [T] { list.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) } }
        return ReimbursementData(
            paidTotal: paidTotal, receivedTotal: receivedTotal, outstanding: outstanding, settled: settled,
            overReimbursed: outstanding < -Self.balanceTolerance,
            lastCheckpoint: pending?.reachedAt ?? last?.reachedAt,
            recentPaid: order(paid.filter { !coveredItems.contains($0.id) }) { $0.date },
            recentReceived: order(received.filter { !coveredReceived.contains($0.id) }) { $0.date },
            earlierPaid: order(paid.filter { coveredItems.contains($0.id) }) { $0.date },
            earlierReceived: order(received.filter { coveredReceived.contains($0.id) }) { $0.date },
            checkpoints: checkpoints.sorted { $0.recordedAt > $1.recordedAt }, pendingCheckpoint: pending)
    }

    /// What's owed back if this one transaction weren't counted as a reimbursement - the number an
    /// incoming payment is checked against, so an over-payment is caught before it makes the balance negative.
    func outstanding(excluding transaction: YouTripTransaction) -> Double {
        let paid = items.filter { !$0.isDeposit }.reduce(0) { $0 + ($1.othersSGD ?? 0) }
        let received = transactions
            .filter { $0.transactionType == .reimbursement && $0.persistentModelID != transaction.persistentModelID }
            .reduce(0) { $0 + abs($1.reimbursementAmount ?? abs($1.amountSGD ?? 0)) }
        return round2(paid - received)
    }

    // MARK: trips

    func tripSummaries() -> [TripSummary] {
        var spend: [PersistentIdentifier: (Double, Int)] = [:]
        for item in items {
            guard let trip = item.trip else { continue }
            let current = spend[trip.persistentModelID] ?? (0, 0)
            spend[trip.persistentModelID] = (current.0 + (item.personalSGD ?? 0), current.1 + 1)
        }
        return trips
            .sorted { ($0.startDate ?? .distantPast, $0.name) > ($1.startDate ?? .distantPast, $1.name) }
            .map { TripSummary(trip: $0, spend: round2(spend[$0.persistentModelID]?.0 ?? 0), itemCount: spend[$0.persistentModelID]?.1 ?? 0) }
    }

    func travelSummary() -> TravelSummary {
        let summaries = tripSummaries()
        var byRoot: [PersistentIdentifier?: Double] = [:]
        for item in items where item.trip != nil {
            if let personal = item.personalSGD, personal != 0 { byRoot[item.rootCategoryID, default: 0] += personal }
        }
        let byID = Dictionary(uniqueKeysWithValues: topLevel.map { ($0.persistentModelID as PersistentIdentifier?, $0) })
        let rows = byRoot.map { (category: byID[$0.key] ?? nil, spend: round2($0.value)) }.sorted { $0.spend > $1.spend }
        let travel = round2(summaries.reduce(0) { $0 + $1.spend })
        let all = categoryTree().totalSGD
        return TravelSummary(trips: summaries, categories: rows, total: travel,
                             shareOfSpending: all > 0 ? (travel / all * 1000).rounded() / 10 : 0)
    }

    func tripDetail(_ trip: Trip) -> TripDetail {
        let summary = tripSummaries().first { $0.trip.persistentModelID == trip.persistentModelID }
            ?? TripSummary(trip: trip, spend: 0, itemCount: 0)
        let fronted = items(in: nil, trip: trip).filter { !$0.isDeposit }.reduce(0) { $0 + ($1.othersSGD ?? 0) }
        return TripDetail(summary: summary, fronted: round2(fronted), tree: categoryTree(trip: trip),
                          entries: activityFeed().filter { $0.trip?.persistentModelID == trip.persistentModelID })
    }

    // MARK: search

    /// One box across transactions, receipt items, receipts, merchants, categories and trips. A plain
    /// case-insensitive substring on each field - predictable, and there's no model behind it.
    func search(_ query: String) -> SearchResults {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return SearchResults(query: query, items: [], transactions: [], receipts: [], trips: []) }
        let hits = items.filter { item in
            ([item.name, item.merchant ?? "", item.tags.joined(separator: " "),
              (item.category?.path ?? []).joined(separator: " "), item.trip?.name ?? ""].joined(separator: " ")).lowercased().contains(needle)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let transactionHits = activityFeed().filter { entry in
            entry.kind == .transaction && ([entry.title, entry.userNote ?? "", entry.trip?.name ?? "",
                                            (entry.category?.category?.path ?? []).joined(separator: " ")].joined(separator: " ")).lowercased().contains(needle)
        }
        var receiptCounts: [PersistentIdentifier: (Receipt, Int)] = [:]
        for hit in hits { if let r = hit.receipt { receiptCounts[r.persistentModelID] = (r, (receiptCounts[r.persistentModelID]?.1 ?? 0) + 1) } }
        return SearchResults(query: query, items: hits, transactions: transactionHits,
                             receipts: receiptCounts.values.map { (receipt: $0.0, matched: $0.1) },
                             trips: trips.filter { $0.name.lowercased().contains(needle) })
    }

    // MARK: trends

    func trends(rangeMonths: Int?, today: Date = Date()) -> TrendsData {
        let current = MonthKey(today)
        let spend = counted.filter { ($0.personalSGD ?? 0) > 0 }
        var byMonth: [MonthKey: Double] = [:]
        for item in spend { if let m = monthKey(item) { byMonth[m, default: 0] += item.personalSGD ?? 0 } }

        var months: [MonthKey] = []
        if let n = rangeMonths { months = (0..<n).map { current.shifted(by: $0 - (n - 1)) } }
        else {
            var cursor = byMonth.keys.min() ?? current
            while cursor <= current { months.append(cursor); cursor = cursor.shifted(by: 1) }
        }
        let usual = usual(before: current)
        let (fraction, elapsedDays) = elapsed(current, today: today)

        var actual: [PersistentIdentifier?: Double] = [:]
        for item in spend where monthKey(item) == current { actual[item.rootCategoryID, default: 0] += item.personalSGD ?? 0 }
        var changes: [CategoryChange] = []
        for root in topLevel {
            let spent = actual[root.persistentModelID] ?? 0
            let expected = (usual.byRoot[root.persistentModelID] ?? 0) * fraction
            if spent != 0 || expected != 0 {
                changes.append(CategoryChange(category: root, actual: round2(spent), delta: usual.months > 0 ? round2(spent - expected) : nil))
            }
        }
        changes.sort { (abs($0.delta ?? 0) == 0 ? $0.actual : abs($0.delta ?? 0)) > (abs($1.delta ?? 0) == 0 ? $1.actual : abs($1.delta ?? 0)) }

        // average daily spend and weekday pattern over the selected window
        let start = (months.first ?? current).firstDay
        let inWindow = spend.filter { ($0.date ?? .distantPast) >= start && ($0.date ?? .distantFuture) <= today }
        let daysCovered = max(1, (Dates.calendar.dateComponents([.day], from: start, to: today.startOfDay).day ?? 0) + 1)
        var weekdayTotals = [Double](repeating: 0, count: 7), weekdayCounts = [Int](repeating: 0, count: 7)
        func weekday(_ d: Date) -> Int { (Dates.calendar.component(.weekday, from: d) + 5) % 7 }  // Monday = 0
        for item in inWindow { weekdayTotals[weekday(item.date!)] += item.personalSGD ?? 0 }
        for offset in 0..<daysCovered { weekdayCounts[weekday(Dates.calendar.date(byAdding: .day, value: offset, to: start)!)] += 1 }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let weekdays = (0..<7).map { WeekdayPoint(weekday: $0, label: names[$0], average: weekdayCounts[$0] > 0 ? round2(weekdayTotals[$0] / Double(weekdayCounts[$0])) : 0) }

        // recurring: the same merchant/item turning up in different months at a similar price
        var groups: [String: [ItemView]] = [:]
        for item in spend {
            let label = (item.merchant == nil || item.merchant == "No receipt yet") ? item.name : item.merchant!
            groups[label.trimmingCharacters(in: .whitespaces).lowercased(), default: []].append(item)
        }
        var recurring: [RecurringRow] = []
        for (_, group) in groups {
            let monthsSeen = Set(group.compactMap(monthKey))
            let amounts = group.compactMap(\.personalSGD).sorted()
            guard monthsSeen.count >= 2, let typical = amounts.isEmpty ? nil : (amounts.count % 2 == 1 ? amounts[amounts.count / 2] : (amounts[amounts.count / 2 - 1] + amounts[amounts.count / 2]) / 2) else { continue }
            let similar = amounts.filter { typical != 0 && abs($0 - typical) / typical <= 0.25 }
            if similar.count >= 2 {
                let first = group[0]
                recurring.append(RecurringRow(name: (first.merchant == nil || first.merchant == "No receipt yet") ? first.name : first.merchant!,
                                              months: monthsSeen.count, count: group.count, typical: round2(typical)))
            }
        }
        recurring.sort { ($0.months, $0.typical) > ($1.months, $1.typical) }

        return TrendsData(
            months: months.map { MonthPoint(month: $0, total: round2(byMonth[$0] ?? 0)) },
            usualMonthly: usual.total.map(round2), dailyActual: cumulative(month: current, throughDay: elapsedDays),
            dailyUsual: usual.cumulative, daysInMonth: current.daysInMonth, todayDay: elapsedDays,
            thisMonth: round2(byMonth[current] ?? 0),
            averageDaily: round2(inWindow.reduce(0) { $0 + ($1.personalSGD ?? 0) } / Double(daysCovered)),
            weekdays: weekdays, changes: changes, recurring: Array(recurring.prefix(6)),
            trips: tripSummaries().sorted { ($0.trip.startDate ?? .distantPast) < ($1.trip.startDate ?? .distantPast) })
    }
}
