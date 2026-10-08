import Foundation

/// What the receipt parser hands back: suggestions only, nothing is saved until the app writes it.
struct ParsedLineItem {
    var name: String
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
}

/// One row read off a YouTrip transaction-list screenshot.
struct ParsedTransaction: Equatable {
    var date: Date?
    var description: String?
    var amountSGD: Double?
    var localAmount: Double?
    var localCurrency: String?
}
