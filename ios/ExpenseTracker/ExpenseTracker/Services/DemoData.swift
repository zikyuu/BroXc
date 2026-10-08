import Foundation
import SwiftData

/// Made-up spending so the app can be explored without any OCR or real data - the same story as the web
/// demo: a stay in Sweden, a weekend in Berlin (shared lunch, partly paid back), three earlier months at
/// home so "usual" and trends have history, a trip with Trip Mode on, and a balance check that finds $48.
@MainActor
enum DemoData {
    static func load(into context: ModelContext) {
        CategorySeeder.seedIfNeeded(in: context)
        let today = Date().startOfDay
        func ago(_ days: Int) -> Date { Dates.calendar.date(byAdding: .day, value: -days, to: today)! }
        func cat(_ name: String) -> Category? {
            ((try? context.fetch(FetchDescriptor<Category>())) ?? []).first { $0.name == name && $0.kind != .misc }
        }

        @discardableResult
        func receipt(_ merchant: String, _ original: String?, _ daysAgo: Int, _ currency: String, _ items: [ParsedLineItem], date: Date? = nil) -> Receipt {
            let r = Receipt(merchant: merchant, merchantOriginal: original, date: date ?? ago(daysAgo), currency: currency,
                            total: round2(items.reduce(0) { $0 + $1.price }), status: .confirmed, rawText: "(demo receipt)", trip: Actions.activeTrip(context))
            context.insert(r)
            for (i, parsed) in items.enumerated() {
                let item = LineItem(name: parsed.name, price: parsed.price, quantity: parsed.quantity, isDeposit: parsed.isDeposit, tags: parsed.tags)
                item.position = i; item.receipt = r
                context.insert(item)
            }
            return r
        }
        @discardableResult
        func charge(_ daysAgo: Int, _ description: String, _ sgd: Double, _ local: Double?, _ currency: String?) -> YouTripTransaction {
            let t = YouTripTransaction(date: ago(daysAgo), description: description, amountSGD: sgd, localAmount: local, localCurrency: currency, trip: Actions.activeTrip(context))
            context.insert(t)
            return t
        }
        func link(_ t: YouTripTransaction, _ r: Receipt, _ status: String, _ note: String? = nil) {
            t.matchedReceipt = r; t.matchStatus = status; t.matchNote = note
        }
        func item(_ name: String, _ price: Double, quantity: Double? = 1, tags: [String] = [], deposit: Bool = false) -> ParsedLineItem {
            ParsedLineItem(name: name, price: price, quantity: quantity, isDeposit: deposit, tags: tags)
        }

        // ---- Sweden (SEK) ----
        let coop = receipt("Large coop", "Stora Coop", 2, "SEK", [
            item("Facial napkins", 41.90, quantity: 2, tags: ["household"]), item("Candy, loose weight", 30.74, quantity: 0.298, tags: ["food", "snacks"]),
            item("Resin cord velvet", 29.90), item("Max white purple", 33.95), item("Hygiene napkins 2 for 30:-", -11.90)])
        let press = receipt("Pressbyran", "Pressbyran", 5, "SEK", [
            item("Coffee", 39, tags: ["food", "drinks"]), item("Sandwich", 55, tags: ["food", "meals out"]), item("?????", 12, tags: ["mystery"])])
        let transit = receipt("SL", "SL", 9, "SEK", [item("Travel card top-up", 300, tags: ["transport"])])
        receipt("ICA Maxi", "ICA Maxi", 12, "SEK", [   // no charge yet: its SGD value is an estimate
            item("Chicken breast", 89.90, tags: ["food", "meat"]), item("Onions", 19.90, tags: ["food", "vege"]), item("Milk", 15.90, tags: ["food"]),
            item("Pant", 2, deposit: true)])
        let tCoop = charge(2, "STORA COOP UPPSALA", 16.50, 124.59, "SEK")
        let tPress = charge(5, "PRESSBYRAN UPPSALA C", 14.10, 106.00, "SEK")
        let tTransit = charge(9, "SL ACCESS", 39.90, 300, "SEK")
        charge(7, "SYSTEMBOLAGET UPPSALA", 28, 210, "SEK")   // receipt lost: stays unmatched
        link(tCoop, coop, "auto"); link(tPress, press, "approved", "linked manually"); link(tTransit, transit, "auto")

        // ---- a weekend in Berlin (EUR): three charges establish the usual rate of about 0.67 EUR per SGD ----
        let berlin = (try? Actions.createTrip(name: "Berlin weekend", start: ago(16), end: ago(14), activate: false, colorHex: "#ff8a75", emoji: "🗼", in: context))
        let cafe = receipt("Cafe Roma", "Cafe Roma", 14, "EUR", [item("Lunch for two", 50, tags: ["food", "meals out"])])
        let bakery = receipt("Backerei Mohr", "Backerei Mohr", 15, "EUR", [item("Bread and pastries", 20, tags: ["food"])])
        let shop = receipt("Museum shop", "Museumsshop", 15, "EUR", [item("Postcards", 30, tags: ["gifts"])])
        let tCafe = charge(14, "CAFE ROMA BERLIN", 88, 50, "EUR")      // far pricier than the usual rate: flagged
        let tBakery = charge(15, "BACKEREI MOHR", 30, 20, "EUR")
        let tShop = charge(15, "MUSEUMSSHOP BERLIN", 45, 30, "EUR")
        charge(16, "RESTAURANT ZUR LINDE", 60, 40, "EUR")              // no receipt
        link(tCafe, cafe, "needs_review", "exchange rate 0.57 EUR/SGD is 15% off the usual 0.67"); link(tBakery, bakery, "auto"); link(tShop, shop, "auto")
        if let berlin { for r in [cafe, bakery, shop] { r.trip = berlin }; for t in [tCafe, tBakery, tShop] { t.trip = berlin } }
        // the Cafe Roma lunch was split with a friend, who has paid part of it back
        try? Actions.setSplit(cafe.lineItems, mode: .shared, shares: [SplitShareInput(person: "me", amount: nil, percentage: 50),
                                                                       SplitShareInput(person: "Sam", amount: nil, percentage: 50)], in: context)
        let paidBack = charge(10, "FROM SAM", 30, nil, nil)
        paidBack.transactionType = .reimbursement; paidBack.trip = nil

        // ---- three earlier months at home (SGD), so "usual", trends and projections have history ----
        let history: [(Int, String, [(String, Double, [String])])] = [
            (3, "Cold Storage", [("Chicken thigh", 9.80, ["food", "meat"]), ("Broccoli", 3.20, ["food", "vege"]), ("Rice 5kg", 12.90, ["food"])]),
            (8, "MRT top-up", [("Card top-up", 30, ["transport"])]),
            (12, "Ramen Bar", [("Ramen set", 16.50, ["food", "meals out"])]),
            (17, "Cold Storage", [("Salmon fillet", 11.40, ["food", "meat"]), ("Onions", 2.10, ["food", "vege"]), ("Milk", 3.50, ["food"])]),
            (21, "Uniqlo", [("T-shirt", 19.90, ["shopping"])]),
            (25, "Guardian", [("Vitamins", 14, ["health"])]),
        ]
        for (monthsAgo, factor) in [(3, 3.6), (2, 4.0), (1, 4.4)] {   // scaled up: an exchange student's month is bigger than one grocery run
            let start = MonthKey.current.shifted(by: -monthsAgo).firstDay
            for (day, merchant, rows) in history {
                guard let date = Dates.calendar.date(byAdding: .day, value: day - 1, to: start) else { continue }
                receipt(merchant, nil, 0, "SGD", rows.map { item($0.0, round2($0.1 * factor), tags: $0.2) }, date: date)
            }
        }

        // ---- the user has confirmed some categories; the rest stay suggestions or unknown, so "Needs a look" has content ----
        let confirmed = ["Coffee": "Drinks", "Sandwich": "Eat Out", "Lunch for two": "Eat Out", "Bread and pastries": "Carbs",
                         "Travel card top-up": "Public Transit", "Postcards": "Souvenirs", "Facial napkins": "Household"]
        for r in (try? context.fetch(FetchDescriptor<Receipt>())) ?? [] {
            for line in r.lineItems { if let name = confirmed[line.name], let c = cat(name) { line.category = c } }
        }

        // ---- Trip Mode is on for a Tallinn trip: the latest charges joined it automatically ----
        if let tallinn = try? Actions.createTrip(name: "Tallinn trip", start: ago(1), end: ago(-4), activate: true, colorHex: "#5d8df6", emoji: "🏰", in: context) {
            coop.trip = tallinn; tCoop.trip = tallinn
        }
        charge(1, "RAKVERE KOHVIK TALLINN", 7.20, 5.00, "EUR")
        charge(0, "BOLT TALLINN", 11.80, 8.20, "EUR")
        try? context.save()

        // ---- balance: a baseline, then activity, then a check that finds $48 the records can't explain ----
        Actions.reconcile(actual: 1500, on: MonthKey.current.firstDay, ledger: Ledger.load(context), in: context)
        for (days, description, sgd) in [(3, "DABBA COFFEE", 6.50), (1, "COMFORT TAXI", 12.00)] { charge(days, description, sgd, nil, nil) }
        try? context.save()
        Actions.reconcile(actual: round2(1500 - 6.50 - 12.00 - 48.00), on: today, ledger: Ledger.load(context), in: context)
    }
}
