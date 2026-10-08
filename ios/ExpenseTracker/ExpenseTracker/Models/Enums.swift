import Foundation

/// How much a user has actually looked at this receipt log.
enum ReviewStatus: String, Codable {
    case confirmed
    /// Default for a fresh parse, or for low-confidence OCR / ambiguous matching.
    case needsReview = "needs_review"
}

/// How a line item counts toward the user's own spend.
enum SplitMode: String, Codable {
    case mine                       // fully the user's own expense
    case notMine = "not_mine"       // paid entirely on someone else's behalf, struck out
    case shared                     // split across multiple people, see LineItemShare
}

/// What kind of money movement a YouTrip transaction actually is — only an expense is a purchase
/// eligible for receipt matching; the rest describe cash moving for other reasons and must never
/// enter personal spending totals or the receipt matcher.
enum TransactionType: String, Codable, CaseIterable {
    case expense                                   // default — an actual purchase
    case reimbursement                             // incoming money reducing what's owed back to the user
    case income                                    // incoming money that isn't a reimbursement (allowance, etc.)
    case refund                                    // incoming money reversing an earlier personal expense
    case transferOwnAccount = "transfer_own_account" // cash movement between the user's own accounts
    case other
}

/// A category's special behaviour, if any.
enum CategoryKind: String, Codable {
    case normal
    case misc       // a deliberate "doesn't fit elsewhere" bucket
    case grocery    // the unitemised bucket for receipt-less supermarket charges
}

/// Where a YouTrip charge's SGD conversion came from, when showing a receipt's items in SGD.
enum SGDSource: String, Codable {
    case native     // already SGD, no conversion needed
    case matched    // exact: implied by its own matched charge
    case estimated  // the usual rate for that currency — flagged, not exact
}

/// How confident the app is in an item's category.
enum CategoryConfidence: String, Codable {
    case confirmed  // the user put it there
    case suggested  // derived from tags/merchant history — a guess
    case unknown    // nothing to go on
}
