import Foundation
import SwiftData

/// The user's own category tree (Food -> Cooking Ingredients -> Meat -> Chicken). Every item sits
/// at one node. Mirrors `categories` in the Python schema.
@Model
final class Category {
    var name: String = ""
    /// Optional at every level; read through `effectiveColorHex`, which falls back to the parent's colour.
    var colorHex: String?
    var icon: String?
    var budgetSGD: Double?
    var kindRaw: String = CategoryKind.normal.rawValue
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify)
    var parent: Category?

    @Relationship(deleteRule: .nullify, inverse: \Category.parent)
    var children: [Category] = []

    @Relationship(deleteRule: .nullify, inverse: \LineItem.category)
    var items: [LineItem] = []

    init(name: String, parent: Category? = nil, colorHex: String? = nil, icon: String? = nil,
         kind: CategoryKind = .normal, sortOrder: Int = 0) {
        self.name = name
        self.parent = parent
        self.colorHex = colorHex
        self.icon = icon
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .normal }
        set { kindRaw = newValue.rawValue }
    }

    /// Names from the top-level ancestor down to this category, e.g. ["Food", "Cooking Ingredients", "Meat"].
    /// Walks via a seen-set so a corrupted parent cycle can't infinite-loop.
    var path: [String] {
        var names: [String] = []
        var node: Category? = self
        var seen = Set<PersistentIdentifier>()
        while let current = node, seen.insert(current.persistentModelID).inserted {
            names.append(current.name)
            node = current.parent
        }
        return names.reversed()
    }

    var pathIDs: [PersistentIdentifier] {
        var ids: [PersistentIdentifier] = []
        var node: Category? = self
        var seen = Set<PersistentIdentifier>()
        while let current = node, seen.insert(current.persistentModelID).inserted {
            ids.append(current.persistentModelID)
            node = current.parent
        }
        return ids.reversed()
    }

    var depth: Int { path.count - 1 }

    var root: Category {
        var node = self
        var seen = Set<PersistentIdentifier>()
        while let parent = node.parent, seen.insert(node.persistentModelID).inserted {
            node = parent
        }
        return node
    }

    /// The category's own colour if it has one, otherwise its nearest coloured ancestor's. Top-level categories give
    /// the Home chart its wedges; a sub-category with its own colour (Vegetables green, Meat red) stands out inside
    /// its parent, and one without just reads as its parent.
    var effectiveColorHex: String {
        var node: Category? = self
        var seen = Set<PersistentIdentifier>()
        while let current = node, seen.insert(current.persistentModelID).inserted {
            if let hex = current.colorHex { return hex }
            node = current.parent
        }
        return Category.fallbackColorHex
    }

    /// Colours offered when editing a category, and drawn from for new sub-categories.
    static let palette = [
        "#e5635a", "#ff8a75", "#f08a24", "#f2c94c", "#a5d86e", "#5fbf6a", "#4fd1a5", "#4fb6d9",
        "#5d8df6", "#7c83f5", "#b36cf0", "#f58bd0", "#c9a877", "#9b6b4f",
    ]

    static let fallbackColorHex = "#a9a39a"

    /// Top-level starter colours, assigned by position — the same palette the web build used.
    static let topLevelColors = [
        "#ff8a75", "#5d8df6", "#7c83f5", "#ffb066", "#b36cf0",
        "#f58bd0", "#a5d86e", "#4fd1a5", "#c9a877",
    ]
}
