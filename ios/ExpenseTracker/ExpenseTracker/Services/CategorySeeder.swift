import Foundation
import SwiftData

/// Fills an empty category table with the starter tree the first time the app launches. Mirrors
/// `seed_default_categories`/`DEFAULT_CATEGORIES` in the Python backend — same names, same shape.
/// Never touches an existing tree (the user's edits are never overwritten).
enum CategorySeeder {
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
                Node("Vegetables", "🥬", .normal), Node("Carbs", "🍞", .normal), Node("Condiments", "🧂", .normal),
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
        Node("Misc", "•", .misc),
    ]

    static func seedIfNeeded(in context: ModelContext) {
        let existing = try? context.fetch(FetchDescriptor<Category>())
        guard (existing?.isEmpty ?? true) else { return }

        for (order, node) in tree.enumerated() {
            insert(node, parent: nil, colorHex: Category.topLevelColors[order % Category.topLevelColors.count],
                   sortOrder: order, into: context)
        }
        try? context.save()
    }

    private static func insert(_ node: Node, parent: Category?, colorHex: String?, sortOrder: Int,
                                into context: ModelContext) {
        let category = Category(name: node.name, parent: parent, colorHex: colorHex, icon: node.icon,
                                 kind: node.kind, sortOrder: sortOrder)
        context.insert(category)
        for (childOrder, child) in node.children.enumerated() {
            insert(child, parent: category, colorHex: nil, sortOrder: childOrder, into: context)
        }
    }
}
