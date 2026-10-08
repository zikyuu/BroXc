import Foundation
import SwiftData

/// How older flat tags and plain words map onto the category tree. Same table as the Python backend.
struct CategoryLookup {
    static let aliases: [String: String] = [
        "meals out": "eat out", "restaurant": "eat out", "restaurants": "eat out", "cafe": "eat out",
        "vege": "vegetables", "veg": "vegetables", "veggies": "vegetables", "vegetable": "vegetables",
        "groceries": "cooking ingredients", "grocery": "cooking ingredients",
        "gifts": "souvenirs", "gift": "souvenirs", "toiletries": "health",
        "transit": "public transit", "bus": "public transit", "train": "public transit",
        "clothing": "clothes",
    ]

    /// lower-cased name -> the deepest category with that name. Misc categories are left out: the same
    /// name exists under several parents, so a bare "misc" tag can't point at one of them.
    private let byName: [String: Category]

    init(_ categories: [Category]) {
        var map: [String: Category] = [:]
        for category in categories where category.kind != .misc {
            let key = category.name.lowercased()
            if let existing = map[key], existing.depth >= category.depth { continue }
            map[key] = category
        }
        byName = map
    }

    /// The deepest category any of these tags names ("mystery" and unknown tags don't count).
    func infer(from tags: [String]) -> Category? {
        var best: Category?
        for tag in tags {
            let cleaned = tag.trimmingCharacters(in: .whitespaces).lowercased()
            guard let category = byName[Self.aliases[cleaned] ?? cleaned] else { continue }
            if best == nil || category.depth > best!.depth { best = category }
        }
        return best
    }
}

/// One spendable thing, ready to display: a real receipt line item, or a card charge with no receipt
/// at all (which still counts - the money genuinely left the card).
struct ItemView: Identifiable {
    let id: String
    let lineItem: LineItem?
    /// For a receipt-less item, the charge itself; for a real item, the charge its receipt is matched to.
    let transaction: YouTripTransaction?
    let receipt: Receipt?
    let name: String
    let quantity: Double?
    let isDeposit: Bool
    let price: Double
    let currency: String?
    let priceSGD: Double?
    let personalPrice: Double
    let personalSGD: Double?
    let othersSGD: Double?
    let sgdSource: SGDSource?
    let splitMode: SplitMode
    let splitUnresolved: Bool
    let tags: [String]
    let category: Category?
    let confidence: CategoryConfidence
    let trip: Trip?
    let matchStatus: String?
    let date: Date?
    let merchant: String?
    /// Read off a real receipt, vs. typed in by hand. Only an itemised one can be decomposed.
    let itemised: Bool

    var isVirtual: Bool { lineItem == nil }
    var rootCategoryID: PersistentIdentifier? { category?.root.persistentModelID }
    var estimated: Bool { sgdSource == .estimated }
}

struct Ledger {
    /// A merchant word must be at least this long to trigger a category guess. Fuzzy character
    /// alignment gave real false positives ("SL" vs "SYSTEMBOLAGET"), a literal substring doesn't.
    static let minHintWordLength = 4
    static let balanceTolerance = 0.005

    let receipts: [Receipt]
    let transactions: [YouTripTransaction]
    let categories: [Category]
    let trips: [Trip]
    let reconciliations: [BalanceReconciliation]
    let checkpoints: [BalanceCheckpoint]
    let rules: [ItemRule]
    let lookup: CategoryLookup
    let items: [ItemView]

    init(receipts: [Receipt], transactions: [YouTripTransaction], categories: [Category], trips: [Trip],
         reconciliations: [BalanceReconciliation] = [], checkpoints: [BalanceCheckpoint] = [],
         rules: [ItemRule] = []) {
        self.receipts = receipts
        self.transactions = transactions
        self.categories = categories
        self.trips = trips
        self.reconciliations = reconciliations
        self.checkpoints = checkpoints
        self.rules = rules
        let lookup = CategoryLookup(categories)
        self.lookup = lookup
        let learned = Dictionary(rules.compactMap { r in r.category.map { (r.name, $0) } }, uniquingKeysWith: { first, _ in first })
        self.items = Ledger.buildItems(receipts: receipts, transactions: transactions, lookup: lookup, learned: learned)
    }

    /// A fresh ledger over everything currently stored.
    @MainActor
    static func load(_ context: ModelContext) -> Ledger {
        func all<T: PersistentModel>(_ type: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
        return Ledger(receipts: all(Receipt.self), transactions: all(YouTripTransaction.self), categories: all(Category.self),
                      trips: all(Trip.self), reconciliations: all(BalanceReconciliation.self),
                      checkpoints: all(BalanceCheckpoint.self), rules: all(ItemRule.self))
    }

    // MARK: building items

    /// The usual local-currency-per-SGD rate for each currency: the median of local / SGD over the
    /// card's own expense charges.
    static func referenceRates(_ transactions: [YouTripTransaction], minSamples: Int = 1) -> [String: Double] {
        var rates: [String: [Double]] = [:]
        for t in transactions where t.transactionType == .expense {
            guard let local = t.localAmount, let sgd = t.amountSGD, local > 0, sgd > 0,
                  let currency = t.localCurrency else { continue }
            rates[currency.uppercased(), default: []].append(local / sgd)
        }
        return rates.compactMapValues { values in
            guard values.count >= minSamples else { return nil }
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        }
    }

    private static func buildItems(receipts: [Receipt], transactions: [YouTripTransaction],
                                   lookup: CategoryLookup, learned: [String: Category]) -> [ItemView] {
        let reference = referenceRates(transactions)
        var transactionForReceipt: [PersistentIdentifier: YouTripTransaction] = [:]
        for t in transactions { if let r = t.matchedReceipt { transactionForReceipt[r.persistentModelID] = t } }

        func rate(for receipt: Receipt) -> (Double, SGDSource)? {
            let code = (receipt.currency ?? "").uppercased()
            if code == "SGD" { return (1, .native) }
            if let t = transactionForReceipt[receipt.persistentModelID], let sgd = t.amountSGD, sgd > 0,
               let total = receipt.total, total > 0 { return (total / sgd, .matched) }   // what actually left the card
            if let usual = reference[code] { return (usual, .estimated) }
            return nil
        }

        // merchant -> its most common category, learned from that merchant's own past receipts. Powers a
        // best-effort guess for a charge with no receipt. Indexed by both the translated and original name.
        var votes: [String: [PersistentIdentifier: (Category, Int)]] = [:]
        for receipt in receipts {
            let names = [receipt.merchant, receipt.merchantOriginal].compactMap { $0 }.filter { !$0.isEmpty }
            guard !names.isEmpty else { continue }
            for item in receipt.lineItems {
                guard let category = item.category ?? lookup.infer(from: item.tags) else { continue }
                for name in names {
                    let current = votes[name, default: [:]][category.persistentModelID]?.1 ?? 0
                    votes[name, default: [:]][category.persistentModelID] = (category, current + 1)
                }
            }
        }
        let hints: [String: Category] = votes.compactMapValues { $0.values.max { $0.1 < $1.1 }?.0 }

        func resolve(explicit: Category?, name: String = "", tags: [String], itemised: Bool) -> (Category?, CategoryConfidence) {
            var category = explicit
            var confidence: CategoryConfidence = explicit != nil ? .confirmed : .unknown
            if category == nil, let remembered = learned[ItemRule.key(name)] { category = remembered; confidence = .suggested }
            if category == nil, let guess = lookup.infer(from: tags) { category = guess; confidence = .suggested }
            // a known grocery spend with no receipt can't be split into meat/veg/etc until one turns up
            if let found = category, !itemised, let grocery = found.children.first(where: { $0.kind == .grocery }) {
                category = grocery
            }
            return (category, confidence)
        }

        var result: [ItemView] = []
        for receipt in receipts {
            let transaction = transactionForReceipt[receipt.persistentModelID]
            let rateInfo = rate(for: receipt)
            for item in receipt.lineItems.sorted(by: { $0.position < $1.position }) {
                let split = item.split
                let (category, confidence) = resolve(explicit: item.category, name: item.name, tags: item.tags, itemised: receipt.isItemised)
                result.append(ItemView(
                    id: item.uid, lineItem: item, transaction: transaction, receipt: receipt,
                    name: item.name, quantity: item.quantity, isDeposit: item.isDeposit, price: item.price,
                    currency: receipt.currency,
                    priceSGD: rateInfo.map { round2(item.price / $0.0) },
                    personalPrice: split.personal,
                    personalSGD: rateInfo.map { round2(split.personal / $0.0) },
                    othersSGD: rateInfo.map { round2(split.others / $0.0) },
                    sgdSource: rateInfo?.1, splitMode: item.splitMode, splitUnresolved: split.unresolved,
                    tags: item.tags, category: category, confidence: confidence, trip: receipt.trip,
                    matchStatus: transaction?.matchStatus, date: receipt.date, merchant: receipt.merchant,
                    itemised: receipt.isItemised))
            }
        }

        // expense charges with no receipt at all get no line item to read from - without this that
        // money is invisible in every total. Reimbursements/income/transfers aren't purchases.
        for t in transactions where t.transactionType == .expense && t.matchedReceipt == nil {
            let amount = t.amountSGD ?? 0
            var guess: Category?
            if let description = t.transactionDescription?.lowercased(), !description.isEmpty {
                var bestLength = 0
                for (merchant, category) in hints {
                    for word in merchant.lowercased().split(separator: " ")
                    where word.count >= minHintWordLength && word.count > bestLength && description.contains(word) {
                        guess = category; bestLength = word.count
                    }
                }
            }
            let (category, confidence) = resolve(explicit: nil, tags: [], itemised: false)
            let finalCategory = guess ?? category
            result.append(ItemView(
                id: "txn-" + t.uid, lineItem: nil, transaction: t, receipt: nil,
                name: t.transactionDescription ?? "Unknown charge", quantity: 1, isDeposit: false,
                price: amount, currency: "SGD", priceSGD: amount, personalPrice: amount, personalSGD: amount,
                othersSGD: 0, sgdSource: .native, splitMode: .mine, splitUnresolved: false, tags: [],
                category: finalCategory, confidence: guess != nil ? .suggested : confidence, trip: t.trip,
                matchStatus: nil, date: t.date, merchant: "No receipt yet", itemised: false))
        }
        return result
    }

    // MARK: lookups

    func items(in range: ClosedRange<Date>? = nil, trip: Trip? = nil) -> [ItemView] {
        items.filter { item in
            if let trip, item.trip?.persistentModelID != trip.persistentModelID { return false }
            if let range { guard let date = item.date, range.contains(date) else { return false } }
            return true
        }
    }

    func items(of transaction: YouTripTransaction) -> [ItemView] {
        items.filter { $0.transaction?.persistentModelID == transaction.persistentModelID }
    }

    func items(of receipt: Receipt) -> [ItemView] {
        items.filter { $0.receipt?.persistentModelID == receipt.persistentModelID }
    }

    /// Real personal spend with a known SGD value and a date - what every chart is made of.
    var counted: [ItemView] {
        items.filter { !$0.isDeposit && $0.personalSGD != nil && $0.date != nil }
    }

    func category(named name: String) -> Category? { categories.first { $0.name == name && $0.kind != .misc } }

    var topLevel: [Category] {
        categories.filter { $0.parent == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var activeTrip: Trip? { trips.first { $0.isActive } }
}
