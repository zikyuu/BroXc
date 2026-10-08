import Foundation
import SwiftData

/// Links parsed receipts to YouTrip charges. Cost = date proximity + how closely the receipt total equals
/// what YouTrip charged in the same currency + fuzzy merchant-name similarity - deterministic and fully
/// explainable. A link the matcher isn't sure about (weak cost, or an exchange rate far from the usual one)
/// is still made, but flagged needs_review so the user can approve or undo it. Nothing waits on the user.
enum Matcher {
    static let dateWeight = 1.0
    static let amountWeight = 1.0
    static let nameWeight = 1.0
    /// A pair costing more than this is rejected rather than forced together - the assignment algorithm
    /// always pairs every receipt it can, however absurd, so without this a receipt whose charge hasn't
    /// been uploaded yet would be force-fitted to the wrong one.
    static let maxAcceptableCost = 3.0
    /// At or below this a link is trusted; between this and the max it's linked but flagged for review.
    static let confidentCost = 1.0
    /// An instant-processing card: even a 1-day gap is unusual (1, not 0, only for midnight/timezone quirks).
    static let dateCostScaleDays = 1.0
    /// A 5% gap between receipt total and YouTrip's charge costs 1.0 (capped at 2.0).
    static let amountGapScale = 20.0
    /// Flag a link whose exchange rate is more than 10% off that currency's usual rate.
    static let fxReviewTolerance = 0.10

    struct Result {
        let receipt: Receipt
        let transaction: YouTripTransaction
        let cost: Double
        let needsReview: Bool
        let note: String?
    }

    static func dateCost(_ receipt: Date?, _ transaction: Date?) -> Double {
        guard let receipt, let transaction else { return 1 }
        return min(Double(Dates.daysApart(receipt, transaction)) / dateCostScaleDays, 2)
    }

    private static func gapCost(_ a: Double, _ b: Double?) -> Double {
        guard let b, b != 0 else { return 1 }
        return min(abs(a - b) / b * amountGapScale, 2)
    }

    /// 0 = the receipt total equals what YouTrip says the merchant charged, in the same currency. The
    /// strongest signal there is: it needs no exchange rate and no readable store name.
    static func amountCost(_ receipt: Receipt, _ t: YouTripTransaction) -> Double {
        guard let total = receipt.total, total != 0 else { return 1 }   // nothing to compare - neutral, not a penalty
        let currency = (receipt.currency ?? "").uppercased()
        if let local = t.localAmount, local != 0, let localCurrency = t.localCurrency {
            if !currency.isEmpty && currency != localCurrency.uppercased() { return 2 }
            return gapCost(total, local)
        }
        if currency == "SGD", let sgd = t.amountSGD, sgd != 0 { return gapCost(total, sgd) }
        return 1
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
        let costs = receipts.map { r in
            transactions.map { t in
                dateWeight * dateCost(r.date, t.date) + amountWeight * amountCost(r, t) + nameWeight * nameCost(r, t.transactionDescription)
            }
        }
        var results: [Result] = []
        for pair in Hungarian.solve(costs) {
            let cost = costs[pair.row][pair.column]
            if cost > maxAcceptableCost { continue }
            let t = transactions[pair.column]
            var notes: [String] = []
            if let fx = fxNote(t, reference: reference) { notes.append(fx) }
            if cost > confidentCost { notes.append(String(format: "weak match (cost %.1f)", cost)) }
            results.append(Result(receipt: receipts[pair.row], transaction: t, cost: cost,
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
