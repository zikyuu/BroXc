import Foundation
import SwiftData

/// One row parsed from a YouTrip transaction-list screenshot. Mirrors `youtrip_transactions` in the
/// Python schema.
@Model
final class YouTripTransaction {
    var uid: String = UUID().uuidString
    /// When it was entered - lets a balance check tell which transactions it already knew about,
    /// since a late-entered back-dated transaction still counts as new information.
    var createdAt: Date = Date()
    var date: Date?
    var transactionDescription: String?
    var amountSGD: Double?
    /// What the merchant actually charged (e.g. 10.00), shown beside the SGD figure on the row.
    var localAmount: Double?
    var localCurrency: String?
    var matchStatusRaw: String?   // auto (matcher confident) | needs_review | approved (a human said yes)
    var matchNote: String?
    var transactionTypeRaw: String = TransactionType.expense.rawValue
    var userNote: String?
    /// How much of an incoming reimbursement actually reduces what's owed (nil = all of it); the
    /// excess over the outstanding balance is treated as income instead of a negative receivable.
    var reimbursementAmount: Double?
    /// Which of the user's own money-in categories this is, when it's income ("Allowance", "Scholarship"...).
    var incomeLabel: String?

    var matchedReceipt: Receipt?
    var trip: Trip?
    /// Only set when transactionType is .refund — which expense this reverses.
    var refundsReceipt: Receipt?

    init(date: Date? = nil, description: String? = nil, amountSGD: Double? = nil,
         localAmount: Double? = nil, localCurrency: String? = nil,
         transactionType: TransactionType = .expense, trip: Trip? = nil) {
        self.date = date
        self.transactionDescription = description
        self.amountSGD = amountSGD
        self.localAmount = localAmount
        self.localCurrency = localCurrency
        self.transactionTypeRaw = transactionType.rawValue
        self.trip = trip
    }

    var matchStatus: String? {
        get { matchStatusRaw }
        set { matchStatusRaw = newValue }
    }

    var transactionType: TransactionType {
        get { TransactionType(rawValue: transactionTypeRaw) ?? .expense }
        set { transactionTypeRaw = newValue.rawValue }
    }

    /// Mirrors ledger.list_transactions' status field: never has a receipt if it isn't an expense,
    /// so "unmatched" would wrongly ask for one.
    var status: String {
        guard transactionType == .expense else { return "not_expense" }
        return matchedReceipt == nil ? "unmatched" : (matchStatus ?? "auto")
    }
}
