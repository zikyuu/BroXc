import Foundation

/// The hand-drawn category icons (in the asset catalog as `cat-<slug>`) and which seeded category each one belongs to.
/// A category's `icon` is either an emoji the user typed or `asset:cat-<slug>`.
enum CategoryArt {
    static let prefix = "asset:"

    static func symbol(slug: String) -> String { "\(prefix)cat-\(slug)" }

    /// Seeded category name -> icon slug.
    static let forName: [String: String] = [
        "Food": "food", "Cooking Ingredients": "cooking", "Meat": "meat", "Chicken": "chicken", "Pork": "pork", "Beef": "beef", "Fish": "fish",
        "Vegetables": "vegetables", "Fruit": "fruit", "Carbs": "carbs", "Condiments": "condiments", "Grocery Shopping": "grocery",
        "Eat Out": "eat-out", "Snacks": "snacks", "Drinks": "drinks", "Transport": "transport", "Public Transit": "public-transit", "Taxi": "taxi",
        "Long Distance": "long-distance", "Accommodation": "accommodation", "Activities": "activities", "Shopping": "shopping", "Clothes": "clothes",
        "Electronics": "electronics", "Beauty": "beauty", "Souvenirs": "souvenirs", "Household": "household", "Health": "health", "Pant": "pant", "Misc": "misc",
    ]

    static func symbol(forCategoryNamed name: String) -> String? { forName[name].map(symbol(slug:)) }

    /// Every icon offered in the category editor, grouped the way the sheet was drawn.
    static let picker: [(group: String, slugs: [String])] = [
        ("Food", ["food", "cooking", "grocery", "eat-out", "snacks", "drinks", "coffee", "ramen", "meat", "chicken", "pork", "beef", "fish", "vegetables", "fruit", "carbs", "condiments"]),
        ("Getting around", ["transport", "public-transit", "taxi", "long-distance", "flights", "train", "ferry"]),
        ("Places", ["accommodation", "hotel", "hostel", "tent", "activities", "attractions", "photos"]),
        ("Things", ["shopping", "beauty", "clothes", "electronics", "souvenirs", "household", "household-items", "games", "books", "work", "phone", "receipt", "insurance", "subscriptions"]),
        ("Health and life", ["health", "medical", "pharmacy", "pant", "film", "haircut", "pets", "fitness", "misc", "unsorted"]),
    ]
}
