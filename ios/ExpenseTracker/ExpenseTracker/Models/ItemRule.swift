import Foundation
import SwiftData

/// "Remember this for next time": a corrected item name -> its category, so the next receipt that has
/// the same item starts with that category as a suggestion. Plays the role the tag-store JSON file did
/// in the Python backend - an append-only correction cache, not a model being retrained.
@Model
final class ItemRule {
    var name: String = ""      // lower-cased, trimmed
    var category: Category?

    init(name: String, category: Category?) {
        self.name = name
        self.category = category
    }

    static func key(_ itemName: String) -> String { itemName.trimmingCharacters(in: .whitespaces).lowercased() }
}
