import Foundation
import SwiftData

/// "Remember this for next time": a corrected item name -> its category, so the next receipt that has
/// the same item starts with that category as a suggestion. Plays the role the tag-store JSON file did
/// in the Python backend - an append-only correction cache, not a model being retrained.
@Model
final class ItemRule {
    /// The item as printed on the receipt, lower-cased and trimmed.
    var name: String = ""
    var category: Category?
    /// What the user renamed it to ("Romantica RosaBand" -> "Cherry tomatoes"), applied whenever it's printed again.
    var displayName: String?

    init(name: String, category: Category?, displayName: String? = nil) {
        self.name = name
        self.category = category
        self.displayName = displayName
    }

    static func key(_ itemName: String) -> String { itemName.trimmingCharacters(in: .whitespaces).lowercased() }
}
