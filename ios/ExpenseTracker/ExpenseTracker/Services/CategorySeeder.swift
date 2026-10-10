import Foundation
import SwiftData

/// Fills an empty category table with the starter tree the first time the app launches. Mirrors
/// `seed_default_categories`/`DEFAULT_CATEGORIES` in the Python backend — same names, same shape.
/// Never touches an existing tree (the user's edits are never overwritten).
enum CategorySeeder {
    /// A nominal type, not a tuple: a tuple typealias can't reference itself (`(..., [Node])` inside
    /// its own definition), since a typealias is a structural substitution, not a real recursive type.
    private struct Node {
        let name: String
        let icon: String
        let kind: CategoryKind
        let children: [Node]

        init(_ name: String, _ icon: String, _ kind: CategoryKind, _ children: [Node] = []) {
            self.name = name
            self.icon = icon
            self.kind = kind
            self.children = children
        }
    }

    private static let tree: [Node] = [
        Node("Food", "🍴", .normal, [
            Node("Cooking Ingredients", "🧺", .normal, [
                Node("Meat", "🥩", .normal, [
                    Node("Chicken", "🍗", .normal), Node("Pork", "🥓", .normal), Node("Beef", "🥩", .normal),
                    Node("Fish", "🐟", .normal), Node("Misc", "•", .misc),
                ]),
                Node("Vegetables", "🥬", .normal), Node("Fruit", "🍎", .normal), Node("Carbs", "🍞", .normal), Node("Condiments", "🧂", .normal),
                Node("Grocery Shopping", "🛒", .grocery),
            ]),
            Node("Eat Out", "🍜", .normal), Node("Snacks", "🍿", .normal), Node("Drinks", "🥤", .normal),
            Node("Misc", "•", .misc),
        ]),
        Node("Transport", "🚆", .normal, [
            Node("Public Transit", "🚌", .normal), Node("Taxi", "🚕", .normal),
            Node("Long Distance", "✈️", .normal), Node("Misc", "•", .misc),
        ]),
        Node("Accommodation", "🛏️", .normal),
        Node("Activities", "🎟️", .normal),
        Node("Shopping", "🛍️", .normal, [
            Node("Clothes", "👕", .normal), Node("Electronics", "🔌", .normal), Node("Misc", "•", .misc),
        ]),
        Node("Souvenirs", "🎁", .normal),
        Node("Household", "🏠", .normal),
        Node("Health", "💊", .normal),
        Node("Pant", "♻️", .deposit),
        Node("Misc", "•", .misc),
    ]

    /// Starter colours for the default sub-categories, so a receipt reads at a glance: vegetables green, meat red,
    /// fruit yellow. Anything not listed (and every "Misc") just inherits its parent's colour.
    static let subColors: [String: String] = [
        "Cooking Ingredients": "#ff8a75", "Meat": "#e5635a", "Chicken": "#f2a65a", "Pork": "#f58bd0", "Beef": "#b5483f", "Fish": "#4fb6d9",
        "Vegetables": "#5fbf6a", "Fruit": "#f2c94c", "Carbs": "#c9a877", "Condiments": "#f08a24",
        "Eat Out": "#b36cf0", "Snacks": "#f58bd0", "Drinks": "#4fb6d9",
        "Public Transit": "#5d8df6", "Taxi": "#f2c94c", "Long Distance": "#7c83f5",
        "Clothes": "#f58bd0", "Electronics": "#4fd1a5",
    ]

    /// Gives an older tree its sub-colours, once, without touching a colour anyone chose.
    static func applySubColorsOnce(in context: ModelContext) {
        let key = "subColorsApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for category in (try? context.fetch(FetchDescriptor<Category>())) ?? [] where category.parent != nil && category.colorHex == nil {
            if let hex = subColors[category.name], category.kind == .normal { category.colorHex = hex }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    static func seedIfNeeded(in context: ModelContext) {
        let existing = try? context.fetch(FetchDescriptor<Category>())
        guard (existing?.isEmpty ?? true) else { ensureDepositCategory(in: context, existing: existing ?? []); return }

        for (order, node) in tree.enumerated() {
            insert(node, parent: nil, colorHex: Category.topLevelColors[order % Category.topLevelColors.count],
                   sortOrder: order, into: context)
        }
        try? context.save()
    }

    /// A tree made before bottle deposits were tracked has no Pant category - add one, leaving everything else alone.
    private static func ensureDepositCategory(in context: ModelContext, existing: [Category]) {
        guard !existing.contains(where: { $0.kind == .deposit }) else { return }
        let top = existing.filter { $0.parent == nil }
        let order = (top.map(\.sortOrder).max() ?? 0) + 1
        context.insert(Category(name: "Pant", parent: nil, colorHex: Category.topLevelColors[top.count % Category.topLevelColors.count],
                                icon: "♻️", kind: .deposit, sortOrder: order))
        try? context.save()
    }

    private static func insert(_ node: Node, parent: Category?, colorHex: String?, sortOrder: Int,
                                into context: ModelContext) {
        let category = Category(name: node.name, parent: parent, colorHex: parent == nil ? colorHex : (node.kind == .normal ? subColors[node.name] : nil), icon: node.icon,
                                 kind: node.kind, sortOrder: sortOrder)
        context.insert(category)
        for (childOrder, child) in node.children.enumerated() {
            insert(child, parent: category, colorHex: nil, sortOrder: childOrder, into: context)
        }
    }
}
