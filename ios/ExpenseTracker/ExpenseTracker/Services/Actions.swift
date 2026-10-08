import Foundation
import SwiftData

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SplitShareInput { var person: String; var amount: Double?; var percentage: Double? }
struct BreakdownPart { var category: Category?; var amount: Double; var name: String? }

/// Every write the screens can make. Each mirrors a function in the Python ledger/database layer.
@MainActor
enum Actions {
    static let tolerance = Ledger.balanceTolerance

    // MARK: saving parsed data

    static func activeTrip(_ context: ModelContext) -> Trip? {
        (try? context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.isActive })))?.first
    }

    /// Saves a parsed receipt. A receipt with no trip of its own joins whichever trip has Trip Mode on.
    @discardableResult
    static func save(_ draft: ReceiptDraft, in context: ModelContext, ledgerRules: [ItemRule] = []) -> Receipt {
        let receipt = Receipt(merchant: draft.merchant, merchantOriginal: draft.merchantOriginal, date: draft.date,
                              currency: draft.currency, total: draft.total, tax: draft.tax, status: .needsReview,
                              suggestedCategory: draft.suggestedCategory, ocrConfidence: draft.ocrConfidence,
                              rawText: draft.rawText, sourceImagePath: draft.sourceImagePath, trip: activeTrip(context))
        context.insert(receipt)
        for (index, parsed) in draft.items.enumerated() {
            let item = LineItem(name: parsed.name, price: parsed.price, quantity: parsed.quantity,
                                originalPrice: parsed.originalPrice, discount: parsed.discount,
                                isDeposit: parsed.isDeposit, tags: parsed.tags)
            item.position = index
            item.receipt = receipt
            context.insert(item)
        }
        try? context.save()
        return receipt
    }

    /// Saves parsed transactions, skipping ones already stored. Screenshots overlap when you scroll, but
    /// two identical rows can also be genuine (two 10 kr rides in a day) - so this compares counts: if the
    /// database already holds N copies of a row, the first N in the upload are the same ones.
    static func saveNew(_ parsed: [ParsedTransaction], in context: ModelContext) -> (added: Int, skipped: Int) {
        func key(_ date: Date?, _ description: String?, _ sgd: Double?, _ local: Double?, _ currency: String?) -> String {
            "\(date?.timeIntervalSince1970 ?? 0)|\(description ?? "")|\(sgd ?? 0)|\(local ?? 0)|\(currency ?? "")"
        }
        var existing: [String: Int] = [:]
        for t in (try? context.fetch(FetchDescriptor<YouTripTransaction>())) ?? [] {
            existing[key(t.date, t.transactionDescription, t.amountSGD, t.localAmount, t.localCurrency), default: 0] += 1
        }
        let trip = activeTrip(context)
        var added = 0, skipped = 0
        for row in parsed {
            let k = key(row.date, row.description, row.amountSGD, row.localAmount, row.localCurrency)
            if existing[k, default: 0] > 0 { existing[k]! -= 1; skipped += 1; continue }
            let t = YouTripTransaction(date: row.date, description: row.description, amountSGD: row.amountSGD,
                                       localAmount: row.localAmount, localCurrency: row.localCurrency, trip: trip)
            context.insert(t)
            added += 1
        }
        try? context.save()
        return (added, skipped)
    }

    // MARK: matches

    static func approve(_ t: YouTripTransaction, in context: ModelContext) {
        if t.matchedReceipt != nil { t.matchStatus = "approved" }
        try? context.save()
    }

    static func unlink(_ t: YouTripTransaction, in context: ModelContext) {
        t.matchedReceipt = nil; t.matchStatus = nil; t.matchNote = nil
        try? context.save()
    }

    /// A human pairing a charge with a receipt the matcher didn't - counts as approved. The receipt's SGD
    /// value then follows the charge, so if the two amounts disagree the note says so.
    static func link(_ t: YouTripTransaction, to receipt: Receipt, in context: ModelContext) {
        var note = "linked manually"
        if let total = receipt.total, let local = t.localAmount, local > 0 {
            let sameCurrency = receipt.currency == nil || t.localCurrency == nil
                || receipt.currency!.uppercased() == t.localCurrency!.uppercased()
            if sameCurrency && abs(total - local) / local > 0.05 {
                note += String(format: " (receipt total %.2f but charged %.2f)", total, local)
            }
        }
        t.matchedReceipt = receipt; t.matchStatus = "approved"; t.matchNote = note
        try? context.save()
    }

    // MARK: categorising

    /// Turns a receipt-less transaction into a matched one backed by a minimal, hand-entered receipt, the
    /// moment a user edits it directly. Returns the one line item, so the caller can edit that. A category
    /// guess the charge was showing survives as a tag (still a suggestion, never silently confirmed).
    @discardableResult
    static func manualItem(for t: YouTripTransaction, guess: Category? = nil, in context: ModelContext) -> LineItem {
        if let receipt = t.matchedReceipt, let first = receipt.lineItems.min(by: { $0.position < $1.position }) { return first }
        let amount = t.localAmount ?? t.amountSGD ?? 0
        let receipt = Receipt(merchant: t.transactionDescription, date: t.date, currency: t.localCurrency ?? "SGD",
                              total: amount, status: .confirmed, trip: t.trip)
        context.insert(receipt)
        let item = LineItem(name: t.transactionDescription ?? "Unknown charge", price: amount)
        item.receipt = receipt
        if let guess { item.tags = [guess.name.lowercased()] }
        context.insert(item)
        t.matchedReceipt = receipt; t.matchStatus = "approved"; t.matchNote = "resolved by editing from the app"
        return item
    }

    static func lineItem(for item: ItemView, in context: ModelContext) -> LineItem {
        if let real = item.lineItem { return real }
        let guess = item.confidence == .suggested ? item.category : nil
        return manualItem(for: item.transaction!, guess: guess, in: context)
    }

    /// Puts items in one category (nil clears it, back to whatever the tags suggest). `alsoSimilar` extends
    /// it to unconfirmed items with the same name; `remember` teaches future receipts.
    static func assignCategory(_ items: [ItemView], to category: Category?, alsoSimilar: Bool = false,
                               remember: Bool = false, ledger: Ledger, in context: ModelContext) {
        var names: [String] = []
        for view in items {
            let line = lineItem(for: view, in: context)
            line.category = category
            names.append(line.name)
        }
        if alsoSimilar, let category {
            let wanted = Set(names.map(ItemRule.key))
            for other in ledger.items where other.confidence != .confirmed && wanted.contains(ItemRule.key(other.name)) {
                lineItem(for: other, in: context).category = category
            }
        }
        if remember, let category { for name in names { learn(name, category, in: context) } }
        try? context.save()
    }

    static func learn(_ name: String, _ category: Category, in context: ModelContext) {
        let key = ItemRule.key(name)
        let existing = ((try? context.fetch(FetchDescriptor<ItemRule>(predicate: #Predicate { $0.name == key }))) ?? []).first
        if let existing { existing.category = category } else { context.insert(ItemRule(name: key, category: category)) }
    }

    /// Confirms each item's current *suggested* category - an explicit "yes, that guess is right", never automatic.
    static func acceptSuggestions(_ items: [ItemView], ledger: Ledger, in context: ModelContext) {
        for view in items where view.confidence == .suggested {
            if let category = view.category { lineItem(for: view, in: context).category = category }
        }
        try? context.save()
    }

    // MARK: splits

    /// Marks line items as fully mine, paid entirely for someone else, or shared. Shared needs a "me" share.
    static func setSplit(_ lines: [LineItem], mode: SplitMode, shares: [SplitShareInput] = [], in context: ModelContext) throws {
        if mode == .shared {
            guard shares.contains(where: { $0.person.trimmingCharacters(in: .whitespaces).lowercased() == "me" }) else {
                throw AppError("A shared item needs a “me” share.")
            }
            for share in shares where (share.amount == nil) == (share.percentage == nil) {
                throw AppError("The share for \(share.person) needs exactly one of amount or percentage.")
            }
        }
        for line in lines {
            line.splitMode = mode
            for old in line.shares { context.delete(old) }
            line.shares = []
            if mode == .shared {
                for share in shares {
                    let row = LineItemShare(person: share.person.trimmingCharacters(in: .whitespaces),
                                            amount: share.amount, percentage: share.percentage)
                    context.insert(row)
                    line.shares.append(row)
                }
            }
        }
        try? context.save()
    }

    /// Sets what part of a transaction is the user's own. Applied as the same percentage to every item: a $120
    /// dinner with a $30 share makes each item 25% mine. 0 means the whole thing was paid for others.
    static func setTransactionSplit(_ t: YouTripTransaction, myShare: Double, in context: ModelContext) throws {
        guard t.transactionType == .expense else { throw AppError("Only an expense can be split.") }
        guard let total = t.amountSGD, total > 0 else { throw AppError("This transaction has no amount to split.") }
        guard myShare >= -tolerance && myShare <= total + tolerance else {
            throw AppError("Your share has to be between $0 and \(Money.string(total)).")
        }
        let lines: [LineItem]
        if let receipt = t.matchedReceipt { lines = receipt.lineItems.sorted { $0.position < $1.position } }
        else { lines = [manualItem(for: t, in: context)] }
        if myShare >= total - tolerance { try setSplit(lines, mode: .mine, in: context) }
        else if myShare <= tolerance { try setSplit(lines, mode: .notMine, in: context) }
        else {
            let mine = (myShare / total * 100 * 10_000).rounded() / 10_000
            try setSplit(lines, mode: .shared, shares: [
                SplitShareInput(person: "me", amount: nil, percentage: mine),
                SplitShareInput(person: "Others", amount: nil, percentage: ((100 - mine) * 10_000).rounded() / 10_000),
            ], in: context)
        }
    }

    // MARK: classifying

    static func removeReceipt(_ receipt: Receipt, in context: ModelContext) {
        for t in (try? context.fetch(FetchDescriptor<YouTripTransaction>())) ?? [] {
            if t.refundsReceipt?.persistentModelID == receipt.persistentModelID { t.refundsReceipt = nil }
            if t.matchedReceipt?.persistentModelID == receipt.persistentModelID { t.matchedReceipt = nil }
        }
        for item in receipt.lineItems { for share in item.shares { context.delete(share) } }
        context.delete(receipt)
    }

    /// Reclassifies a transaction. Anything that isn't an expense leaves the matcher, personal spend and any
    /// trip it was auto-tagged into. Turning an expense into something else also drops the hand-made receipt
    /// standing in for it; a receipt read off a photo is kept and simply becomes unmatched.
    static func classify(_ t: YouTripTransaction, as type: TransactionType, refunds: Receipt? = nil,
                         reimbursementAmount: Double? = nil, in context: ModelContext) throws {
        if let reimbursementAmount, !(0...(abs(t.amountSGD ?? 0) + tolerance)).contains(reimbursementAmount) {
            throw AppError("The reimbursed part can’t be more than the payment itself.")
        }
        if type == .expense {
            t.transactionType = .expense
            t.refundsReceipt = nil
            t.reimbursementAmount = nil
        } else {
            if let receipt = t.matchedReceipt, !receipt.isItemised { removeReceipt(receipt, in: context) }
            t.transactionType = type
            t.refundsReceipt = type == .refund ? refunds : nil
            t.reimbursementAmount = type == .reimbursement ? reimbursementAmount : nil
            t.matchedReceipt = nil; t.matchStatus = nil; t.matchNote = nil; t.trip = nil
        }
        try? context.save()
    }

    static func setNote(_ t: YouTripTransaction, _ note: String?, in context: ModelContext) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        t.userNote = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try? context.save()
    }

    /// Removes a transaction. A hand-made receipt that existed only to describe it goes too, but a receipt
    /// read off a photo is kept - it just becomes an unmatched receipt again.
    static func delete(_ t: YouTripTransaction, in context: ModelContext) {
        if let receipt = t.matchedReceipt, !receipt.isItemised { removeReceipt(receipt, in: context) }
        context.delete(t)
        try? context.save()
    }

    /// Describes one transaction as several categorised amounts, e.g. a $150 Splitwise settlement as Food $50 +
    /// Transport $88 + Souvenirs $10, with the rest left Unsorted. The parts are the composition of the same
    /// money, so they replace the single item rather than adding to it: the total never changes.
    static func breakdown(_ t: YouTripTransaction, parts rawParts: [BreakdownPart], in context: ModelContext) throws {
        guard t.transactionType == .expense else { throw AppError("Only an expense can be broken down.") }
        if let receipt = t.matchedReceipt, receipt.isItemised {
            throw AppError("This transaction already has an itemised receipt, so it doesn’t need a manual breakdown.")
        }
        let parts = rawParts.filter { $0.amount > 0 }
        guard !parts.isEmpty else { throw AppError("Add at least one amount.") }
        let charged = t.amountSGD ?? 0
        let assigned = round2(parts.reduce(0) { $0 + $1.amount })
        guard assigned <= charged + tolerance else {
            throw AppError("Those add up to \(Money.string(assigned)), more than the \(Money.string(charged)) charged.")
        }
        let receipt: Receipt
        if let existing = t.matchedReceipt {
            receipt = existing
            for item in existing.lineItems { for share in item.shares { context.delete(share) }; context.delete(item) }
            existing.currency = "SGD"; existing.total = charged
        } else {
            receipt = Receipt(merchant: t.transactionDescription, date: t.date, currency: "SGD", total: charged,
                              status: .confirmed, trip: t.trip)
            context.insert(receipt)
            t.matchedReceipt = receipt; t.matchStatus = "approved"; t.matchNote = "broken down by hand"
        }
        var position = 0
        for part in parts {
            let item = LineItem(name: part.name ?? part.category?.name ?? "Other", price: part.amount, category: part.category)
            item.position = position; position += 1
            item.receipt = receipt
            context.insert(item)
        }
        let remainder = round2(charged - assigned)
        if remainder > tolerance {
            let item = LineItem(name: "Unsorted remainder", price: remainder)
            item.position = position
            item.receipt = receipt
            context.insert(item)
        }
        try? context.save()
    }

    // MARK: trips

    @discardableResult
    static func createTrip(name: String, start: Date?, end: Date?, activate: Bool, colorHex: String?, emoji: String?,
                           in context: ModelContext) throws -> Trip {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw AppError("A trip needs a name.") }
        let trip = Trip(name: trimmed, startDate: start, endDate: end, isActive: false, colorHex: colorHex, emoji: emoji)
        context.insert(trip)
        if activate { setActive(trip, in: context) }
        try? context.save()
        return trip
    }

    /// Turns Trip Mode on for one trip (only one is active at a time), or off entirely with nil.
    static func setActive(_ trip: Trip?, in context: ModelContext) {
        for other in (try? context.fetch(FetchDescriptor<Trip>())) ?? [] { other.isActive = false }
        trip?.isActive = true
        try? context.save()
    }

    static func assign(_ t: YouTripTransaction, to trip: Trip?, in context: ModelContext) {
        t.trip = trip
        t.matchedReceipt?.trip = trip   // an item's trip is read from its receipt - they must agree
        try? context.save()
    }

    static func assign(_ receipt: Receipt, to trip: Trip?, in context: ModelContext) {
        receipt.trip = trip
        try? context.save()
    }

    // MARK: balance

    /// Records the user's real balance. The first is just a baseline; after that, whatever the tracked
    /// transactions can't explain becomes "untracked" - no merchant, date or category invented.
    @discardableResult
    static func reconcile(actual: Double, on date: Date, ledger: Ledger, in context: ModelContext)
        -> (implied: Double?, gap: Double) {
        let implied = ledger.currentBalance?.implied
        let gap = implied.map { round2($0 - actual) } ?? 0
        let known = ledger.transactions.map(\.createdAt).max()
        context.insert(BalanceReconciliation(reconciledOn: date, actualSGD: actual, impliedSGD: implied,
                                             untrackedSGD: gap, knownThrough: known))
        try? context.save()
        return (implied, gap)
    }

    /// When the paid-for-others balance has settled to exactly zero, remember it (once per settled state).
    static func recordCheckpointIfNeeded(_ data: ReimbursementData, in context: ModelContext) {
        guard let pending = data.pendingCheckpoint else { return }
        context.insert(BalanceCheckpoint(reachedAt: pending.reachedAt, paidTotal: pending.paidTotal,
                                         receivedTotal: pending.receivedTotal, coveredItemIDs: pending.itemIDs,
                                         coveredReimbursementIDs: pending.reimbursementIDs))
        try? context.save()
    }

    // MARK: categories

    @discardableResult
    static func createCategory(name: String, parent: Category?, icon: String?, colorHex: String?,
                               in context: ModelContext) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw AppError("A category needs a name.") }
        let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let siblings = all.filter { $0.parent?.persistentModelID == parent?.persistentModelID }
        if siblings.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            throw AppError("There’s already a “\(trimmed)” here.")
        }
        let order = (siblings.map(\.sortOrder).max() ?? -1) + 1
        var color = colorHex
        if parent == nil && color == nil { color = Category.topLevelColors[order % Category.topLevelColors.count] }
        let category = Category(name: trimmed, parent: parent, colorHex: parent == nil ? color : nil, icon: icon, sortOrder: order)
        context.insert(category)
        try? context.save()
        return category
    }

    /// Removes a category without losing anything: its sub-categories and items move up to its parent
    /// (or become unsorted at the top level).
    @discardableResult
    static func deleteCategory(_ category: Category, in context: ModelContext) -> Int {
        let parent = category.parent
        let moved = category.items.count
        for item in category.items { item.category = parent }
        for child in category.children {
            if parent == nil { child.colorHex = child.colorHex ?? category.colorHex }  // it was inheriting this colour
            child.parent = parent
        }
        for rule in (try? context.fetch(FetchDescriptor<ItemRule>())) ?? [] where rule.category?.persistentModelID == category.persistentModelID {
            rule.category = parent
        }
        context.delete(category)
        try? context.save()
        return moved
    }

    static func canMove(_ category: Category, into parent: Category?) -> Bool {
        guard let parent else { return true }
        return parent.persistentModelID != category.persistentModelID && !parent.pathIDs.contains(category.persistentModelID)
    }

    // MARK: everything

    /// Wipes all tracked data (not the starter categories' existence - they're re-seeded when empty).
    static func eraseEverything(in context: ModelContext) {
        func wipe<T: PersistentModel>(_ type: T.Type) { for row in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(row) } }
        wipe(LineItemShare.self); wipe(LineItem.self); wipe(YouTripTransaction.self); wipe(Receipt.self)
        wipe(ItemRule.self); wipe(BalanceReconciliation.self); wipe(BalanceCheckpoint.self); wipe(Trip.self)
        wipe(Category.self)
        try? context.save()
        CategorySeeder.seedIfNeeded(in: context)
    }
}
