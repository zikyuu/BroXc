import Foundation
import SwiftData

/// Pipeline's output for one receipt, still provisional until reviewed. Mirrors `receipts` in the
/// Python schema. `suggestedCategory` is only ever "Mystery" or nil — whole receipt unreadable, not
/// a real category.
@Model
final class Receipt {
    var merchant: String?
    /// Store name as printed on the original-language receipt, for matching against YouTrip's
    /// description (which is never translated).
    var merchantOriginal: String?
    var date: Date?
    var currency: String?
    var total: Double?
    /// GST/VAT on the receipt total — receipt-level, not per-item like `LineItem.isDeposit`.
    var tax: Double?
    var statusRaw: String = ReviewStatus.needsReview.rawValue
    var suggestedCategory: String?
    var ocrConfidence: Double?
    /// Raw OCR text — kept so a receipt that was genuinely read off a photo/screenshot can be told
    /// apart from one typed in by hand (e.g. a manual breakdown), which must never claim to be itemised.
    var rawText: String?
    var sourceImagePath: String?

    @Relationship(deleteRule: .cascade, inverse: \LineItem.receipt)
    var lineItems: [LineItem] = []

    var trip: Trip?

    @Relationship(deleteRule: .nullify, inverse: \YouTripTransaction.matchedReceipt)
    var matchedTransaction: YouTripTransaction?

    init(merchant: String? = nil, merchantOriginal: String? = nil, date: Date? = nil,
         currency: String? = nil, total: Double? = nil, tax: Double? = nil,
         status: ReviewStatus = .needsReview, suggestedCategory: String? = nil,
         ocrConfidence: Double? = nil, rawText: String? = nil, sourceImagePath: String? = nil,
         trip: Trip? = nil) {
        self.merchant = merchant
        self.merchantOriginal = merchantOriginal
        self.date = date
        self.currency = currency
        self.total = total
        self.tax = tax
        self.statusRaw = status.rawValue
        self.suggestedCategory = suggestedCategory
        self.ocrConfidence = ocrConfidence
        self.rawText = rawText
        self.sourceImagePath = sourceImagePath
        self.trip = trip
    }

    var status: ReviewStatus {
        get { ReviewStatus(rawValue: statusRaw) ?? .needsReview }
        set { statusRaw = newValue.rawValue }
    }

    /// Read off a real receipt (photo or screenshot), vs. typed in by hand for a transaction with no
    /// receipt. Only an itemised receipt can be decomposed into Meat/Vegetables/etc.
    var isItemised: Bool {
        (rawText?.isEmpty == false) || (sourceImagePath?.isEmpty == false)
    }
}
