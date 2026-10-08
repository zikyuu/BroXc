import Foundation
import SwiftData

/// One person's portion of a SHARED line item. Set exactly one of amount/percentage. Mirrors
/// `line_item_shares` in the Python schema.
@Model
final class LineItemShare {
    /// "me" for the user's own portion, otherwise a name.
    var person: String = ""
    var amount: Double?
    var percentage: Double?

    init(person: String, amount: Double? = nil, percentage: Double? = nil) {
        self.person = person
        self.amount = amount
        self.percentage = percentage
    }
}

/// A single line parsed off a receipt. Mirrors `line_items` in the Python schema.
@Model
final class LineItem {
    /// Stable id that survives relaunches - checkpoints and drag-and-drop refer to items by it.
    var uid: String = UUID().uuidString
    /// Order within its receipt (relationship arrays have no inherent order).
    var position: Int = 0
    var name: String = ""
    var price: Double = 0
    var quantity: Double? = 1.0
    var translatedText: String?
    var originalPrice: Double?
    /// Special offers etc., price markdowns.
    var discount: Double?
    /// Sweden/Germany/Finland bottle pant/Pfand/pantti deposit refund — its own line, never merged
    /// as a discount even when negative, and always excluded from spending totals.
    var isDeposit: Bool = false
    /// Per-item flat labels, e.g. ["food", "meats"] — "mystery" means this one line is unreadable.
    /// Kept alongside the category tree as an older, looser way to tag something; the tree is what
    /// actually drives spending breakdowns now.
    var tags: [String] = []
    var splitModeRaw: String = SplitMode.mine.rawValue

    @Relationship(deleteRule: .cascade)
    var shares: [LineItemShare] = []  // only populated when splitMode is .shared

    var receipt: Receipt?
    /// nil until a human (or a confirmed suggestion) puts it somewhere; see CategoryConfidence.
    var category: Category?

    init(name: String, price: Double, quantity: Double? = 1.0, translatedText: String? = nil,
         originalPrice: Double? = nil, discount: Double? = nil, isDeposit: Bool = false,
         tags: [String] = [], splitMode: SplitMode = .mine, category: Category? = nil) {
        self.name = name
        self.price = price
        self.quantity = quantity
        self.translatedText = translatedText
        self.originalPrice = originalPrice
        self.discount = discount
        self.isDeposit = isDeposit
        self.tags = tags
        self.splitModeRaw = splitMode.rawValue
        self.category = category
    }

    var splitMode: SplitMode {
        get { SplitMode(rawValue: splitModeRaw) ?? .mine }
        set { splitModeRaw = newValue.rawValue }
    }

    /// (personal, others, unresolved) in the receipt's own currency. A SHARED item with no "me"
    /// share recorded can't be split honestly, so it counts fully as personal (never silently
    /// understating spend) and is flagged unresolved for the UI to ask about.
    var split: (personal: Double, others: Double, unresolved: Bool) {
        switch splitMode {
        case .notMine:
            return (0, price, false)
        case .shared:
            guard let mine = shares.first(where: { $0.person.lowercased() == "me" }) else {
                return (price, 0, true)
            }
            let personal = mine.amount ?? price * (mine.percentage ?? 0) / 100
            return (personal, price - personal, false)
        case .mine:
            return (price, 0, false)
        }
    }
}
