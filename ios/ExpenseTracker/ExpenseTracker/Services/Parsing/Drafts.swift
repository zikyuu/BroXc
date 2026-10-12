import Foundation

/// What the receipt parser hands back: suggestions only, nothing is saved until the app writes it.
struct ParsedLineItem {
    var name: String
    /// Set when `name` has been translated: the text as printed.
    var originalName: String?
    var price: Double
    var quantity: Double? = 1
    var originalPrice: Double?
    var discount: Double?
    var isDeposit = false
    /// Flat labels, e.g. ["mystery"] for a line that was unreadable.
    var tags: [String] = []
}

struct ReceiptDraft {
    var merchant: String?
    var merchantOriginal: String?
    var date: Date?
    var currency: String?
    var total: Double?
    var tax: Double?
    var items: [ParsedLineItem] = []
    var suggestedCategory: String?
    var ocrConfidence: Double?
    var rawText: String?
    var sourceImagePath: String?
    /// Prices that were unreadable and were worked out from the receipt's total instead (one sentence each).
    var repairs: [String] = []
}

/// One row read off a YouTrip transaction-list screenshot.
struct ParsedTransaction: Equatable {
    var date: Date?
    var description: String?
    var amountSGD: Double?
    var localAmount: Double?
    var localCurrency: String?
    /// What the description suggests: a top-up or refund is not a purchase. Only a suggestion - the user can change it.
    var transactionType: TransactionType = .expense
    /// Which account's history this came from.
    var account: Account = .youtrip
    /// Money leaving the account. For YouTrip that's every expense; DBS and PayLah say it outright.
    var isOutflow = false
    /// Who a payment to a person went to ("rayner"); nil for shops.
    var payee: String?
}
