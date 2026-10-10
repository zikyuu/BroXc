import Foundation
import SwiftData

/// Links parsed receipts to YouTrip charges. The rule is exact: YouTrip shows the amount the merchant actually
/// charged in its own currency (395.39 kr), so a receipt can only belong to a charge whose local amount equals
/// the receipt total to the cent (0.01 for rounding) - no exchange rate, no "close enough". A charge with no
/// local amount can only be matched to a receipt in SGD, otherwise it's left for a manual link.
/// Among the charges that DO agree on amount, date proximity and the fuzzy merchant name pick the pairing, and
/// anything not clear-cut (several candidates with the same amount, dates apart, odd exchange rate) is linked
/// but flagged needs_review. Nothing waits on the user.
enum Matcher {
    /// Largest amount difference still treated as equal (a rounding cent).
    static let amountTolerance = 0.0101
    /// Beyond this many days apart the merchant names must also agree, or the pair is rejected.
    static let maxDaysWithoutName = 2
    /// A name this similar (0...1) counts as "the same merchant".
    static let sameMerchantSimilarity = 0.7
    /// Flag a link whose exchange rate is more than 10% off that currency's usual rate.
    static let fxReviewTolerance = 0.10
    /// Cost of a pair that is not allowed; high enough that the assignment never prefers it.
    private static let forbidden = 1000.0

    struct Result {
        let receipt: Receipt
        let transaction: YouTripTransaction
        let cost: Double
        let needsReview: Bool
        let note: String?
    }

    static func dateCost(_ receipt: Date?, _ transaction: Date?) -> Double {
        guard let receipt, let transaction else { return 1 }
        return min(Double(Dates.daysApart(receipt, transaction)), 2)
    }

    /// True only when the receipt total equals the amount YouTrip charged, in the same currency.
    static func amountsAgree(_ receipt: Receipt, _ t: YouTripTransaction) -> Bool {
        guard let total = receipt.total, total != 0 else { return false }
        let currency = (receipt.currency ?? "").uppercased()
        if let local = t.localAmount, local != 0, let localCurrency = t.localCurrency {
            guard currency.isEmpty || currency == localCurrency.uppercased() else { return false }
            return abs(total - local) <= amountTolerance
        }
        // no local amount shown: the card was charged in SGD, so only an SGD receipt can be compared exactly
        if currency == "SGD", let sgd = t.amountSGD, sgd != 0 { return abs(total - sgd) <= amountTolerance }
        return false
    }

    /// nil when the pair isn't allowed. Otherwise date proximity + name difference (the amount already agrees).
    static func pairCost(_ receipt: Receipt, _ t: YouTripTransaction) -> Double? {
        guard amountsAgree(receipt, t) else { return nil }
        let name = nameCost(receipt, t.transactionDescription)
        if let r = receipt.date, let d = t.date, Dates.daysApart(r, d) > maxDaysWithoutName, 1 - name < sameMerchantSimilarity {
            return nil   // same amount but days apart and a different-looking merchant: a coincidence, not a match
        }
        return dateCost(receipt.date, t.date) + name
    }

    /// Best of the translated and original-language merchant names - either matching well is enough.
    static func nameCost(_ receipt: Receipt, _ description: String?) -> Double {
        guard let description, !description.isEmpty else { return 1 }
        let names = [receipt.merchant, receipt.merchantOriginal].compactMap { $0 }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return 1 }
        return 1 - (names.map { Fuzzy.partialRatio($0, description) }.max() ?? 0) / 100
    }

    /// A warning when the rate on this charge is far from the usual one for its currency. Needs history.
    static func fxNote(_ t: YouTripTransaction, reference: [String: Double]) -> String? {
        let currency = (t.localCurrency ?? "").uppercased()
        guard let usual = reference[currency], let local = t.localAmount, let sgd = t.amountSGD, sgd != 0 else { return nil }
        let rate = local / sgd
        let deviation = abs(rate - usual) / usual
        guard deviation > fxReviewTolerance else { return nil }
        return String(format: "exchange rate %.2f %@/SGD is %.0f%% off the usual %.2f", rate, currency, deviation * 100, usual)
    }

    static func match(receipts: [Receipt], transactions: [YouTripTransaction], reference: [String: Double]) -> [Result] {
        guard !receipts.isEmpty, !transactions.isEmpty else { return [] }
        let costs = receipts.map { r in transactions.map { t in pairCost(r, t) ?? forbidden } }
        var results: [Result] = []
        for pair in Hungarian.solve(costs) {
            let cost = costs[pair.row][pair.column]
            if cost >= forbidden { continue }
            let r = receipts[pair.row], t = transactions[pair.column]
            var notes: [String] = []
            if let fx = fxNote(t, reference: reference) { notes.append(fx) }
            if let rd = r.date, let td = t.date {
                let gap = Dates.daysApart(rd, td)
                if gap > 1 { notes.append("receipt and charge are \(gap) days apart") }
            } else {
                notes.append("no date to compare")
            }
            let rivalCharges = costs[pair.row].filter { $0 < forbidden }.count
            let rivalReceipts = costs.filter { $0[pair.column] < forbidden }.count
            if rivalCharges > 1 || rivalReceipts > 1 { notes.append("other receipts or charges have this exact amount too") }
            results.append(Result(receipt: r, transaction: t, cost: cost,
                                  needsReview: !notes.isEmpty, note: notes.isEmpty ? nil : notes.joined(separator: "; ")))
        }
        return results
    }

    /// Full cycle: take whatever's currently unmatched, run the algorithm, write accepted matches back.
    /// Safe to call repeatedly - already-matched rows are excluded, so a link already made is never reconsidered.
    @MainActor @discardableResult
    static func run(in context: ModelContext) -> [Result] {
        let receipts = (try? context.fetch(FetchDescriptor<Receipt>())) ?? []
        let transactions = (try? context.fetch(FetchDescriptor<YouTripTransaction>())) ?? []
        let matchedReceipts = Set(transactions.compactMap { $0.matchedReceipt?.persistentModelID })
        let openReceipts = receipts.filter { !matchedReceipts.contains($0.persistentModelID) }
        let openTransactions = transactions.filter { $0.transactionType == .expense && $0.matchedReceipt == nil }
        let results = match(receipts: openReceipts, transactions: openTransactions,
                            reference: Ledger.referenceRates(transactions, minSamples: 3))
        for r in results {
            r.transaction.matchedReceipt = r.receipt
            r.transaction.matchStatus = r.needsReview ? "needs_review" : "auto"
            r.transaction.matchNote = r.note
        }
        try? context.save()
        return results
    }
}
