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
            ]),
            Node("Eat Out", "🍜", .normal), Node("Snacks", "🍿", .normal), Node("Drinks", "🥤", .normal),
            Node("Misc", "•", .misc),
        ]),
        // a place you shop, not a kind of food: for supermarket charges with no receipt, and as the "kind of visit" on receipts
        Node("Grocery Shopping", "🛒", .grocery),
        Node("Transport", "🚆", .normal, [
            Node("Public Transit", "🚌", .normal), Node("Taxi", "🚕", .normal),
            Node("Long Distance", "✈️", .normal), Node("Misc", "•", .misc),
        ]),
        Node("Accommodation", "🛏️", .normal),
        Node("Activities", "🎟️", .normal),
        Node("Shopping", "🛍️", .normal, [
            Node("Clothes", "👕", .normal), Node("Electronics", "🔌", .normal), Node("Beauty", "💄", .normal), Node("Misc", "•", .misc),
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
        "Cooking Ingredients": "#f2a08f", "Meat": "#e8786a", "Chicken": "#f5b27a", "Pork": "#f2a9c4", "Beef": "#b5675a", "Fish": "#8fb4d6",
        "Vegetables": "#8fbf7a", "Fruit": "#f5c26b", "Carbs": "#c9a27e", "Condiments": "#ee9a45",
        "Eat Out": "#a99bd8", "Snacks": "#f2a9c4", "Drinks": "#8fb4d6",
        "Public Transit": "#7f9fd8", "Taxi": "#f5c26b", "Long Distance": "#a99bd8",
        "Clothes": "#f2a9c4", "Electronics": "#7cc6b0", "Beauty": "#f2a9c4",
    ]
    private static let legacySubColors: [String: String] = [
        "Cooking Ingredients": "#ff8a75", "Meat": "#e5635a", "Chicken": "#f2a65a", "Pork": "#f58bd0", "Beef": "#b5483f", "Fish": "#4fb6d9",
        "Vegetables": "#5fbf6a", "Fruit": "#f2c94c", "Carbs": "#c9a877", "Condiments": "#f08a24",
        "Eat Out": "#b36cf0", "Snacks": "#f58bd0", "Drinks": "#4fb6d9",
        "Public Transit": "#5d8df6", "Taxi": "#f2c94c", "Long Distance": "#7c83f5",
        "Clothes": "#f58bd0", "Electronics": "#4fd1a5",
    ]

    /// Moves a category tree made before the BroXc theme onto the new colours and the hand-drawn icons - only where the colour or icon
    /// is still the untouched default, so anything the user chose themselves is left alone. Runs once.
    static func applyBroXcThemeOnce(in context: ModelContext) {
        let key = "broxcThemeApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var legacyEmoji: [String: String] = [:]
        func walk(_ nodes: [Node]) { for n in nodes { legacyEmoji[n.name] = n.icon; walk(n.children) } }
        walk(tree)
        for category in (try? context.fetch(FetchDescriptor<Category>())) ?? [] {
            if let hex = category.colorHex?.lowercased() {
                if category.parent == nil, let i = Category.legacyTopLevelColors.firstIndex(of: hex) { category.colorHex = Category.topLevelColors[i] }
                else if category.parent != nil, legacySubColors[category.name]?.lowercased() == hex, let new = subColors[category.name] { category.colorHex = new }
            }
            if let art = CategoryArt.symbol(forCategoryNamed: category.name), category.icon == nil || category.icon == legacyEmoji[category.name] { category.icon = art }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

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

    /// A tree made before Beauty existed gets it under Shopping, once, unless the user already has a category by that name.
    static func ensureBeautyOnce(in context: ModelContext) {
        let key = "beautyCategoryEnsured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if !all.isEmpty, !all.contains(where: { $0.name == "Beauty" }), let shopping = all.first(where: { $0.name == "Shopping" && $0.parent == nil }) {
            let order = (shopping.children.map(\.sortOrder).max() ?? 0) + 1
            context.insert(Category(name: "Beauty", parent: shopping, colorHex: "#f2a9c4", icon: CategoryArt.symbol(slug: "beauty"), sortOrder: order))
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Grocery Shopping used to sit inside Cooking Ingredients. It's a store type, not a kind of food, so it moves to the top level, once.
    static func moveGroceryToTopLevelOnce(in context: ModelContext) {
        let key = "groceryTopLevel"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if let grocery = all.first(where: { $0.kind == .grocery && $0.parent != nil }) {
            let top = all.filter { $0.parent == nil }
            grocery.parent = nil
            grocery.colorHex = grocery.colorHex ?? "#8ab8ff"
            grocery.sortOrder = (top.map(\.sortOrder).max() ?? 0) + 1
            try? context.save()
        }
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
                                icon: CategoryArt.symbol(forCategoryNamed: "Pant") ?? "♻️", kind: .deposit, sortOrder: order))
        try? context.save()
    }

    private static func insert(_ node: Node, parent: Category?, colorHex: String?, sortOrder: Int,
                                into context: ModelContext) {
        let category = Category(name: node.name, parent: parent, colorHex: parent == nil ? colorHex : (node.kind == .normal ? subColors[node.name] : nil),
                                 icon: CategoryArt.symbol(forCategoryNamed: node.name) ?? node.icon,
                                 kind: node.kind, sortOrder: sortOrder)
        context.insert(category)
        for (childOrder, child) in node.children.enumerated() {
            insert(child, parent: category, colorHex: nil, sortOrder: childOrder, into: context)
        }
    }
}
