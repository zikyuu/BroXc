import Foundation
import SwiftData

/// A trip is a context/tag, not a spending category — the same item can be both Food -> Eat Out and
/// "Tallinn Trip" at once, see Trip Mode. Mirrors `trips` in the Python schema.
@Model
final class Trip {
    var name: String = ""
    var startDate: Date?
    var endDate: Date?
    /// Whether Trip Mode is currently on for this trip — new receipts/expenses auto-tag while true.
    /// Only one trip is ever active at once; enforced by TripStore, not by the model itself.
    var isActive: Bool = false
    var colorHex: String?
    var emoji: String?

    @Relationship(deleteRule: .nullify, inverse: \Receipt.trip)
    var receipts: [Receipt] = []

    @Relationship(deleteRule: .nullify, inverse: \YouTripTransaction.trip)
    var transactions: [YouTripTransaction] = []

    init(name: String, startDate: Date? = nil, endDate: Date? = nil, isActive: Bool = false,
         colorHex: String? = nil, emoji: String? = nil) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
        self.colorHex = colorHex
        self.emoji = emoji
    }
}
