import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class LedgerTests: LedgerTestCase {
    func testSeededTree() {
        let meat = category("Meat")
        XCTAssertEqual(meat.path, ["Food", "Cooking Ingredients", "Meat"])
        XCTAssertNotEqual(meat.effectiveColorHex, category("Vegetables").effectiveColorHex, "sub-categories have their own colours")
        XCTAssertEqual(category("Accommodation").effectiveColorHex, category("Accommodation").colorHex, "a top-level category uses its own colour")
        XCTAssertEqual(category("Chicken").depth, 3)
    }

    func testPersonalSpendSplitsAndTrips() throws {
        addReceipt("Home cafe", "2026-03-01", [("coffee", 10, ["coffee"])])
        let trip = try Actions.createTrip(name: "Tallinn trip", start: day("2026-04-01"), end: day("2026-04-10"), activate: true,
                                          colorHex: nil, emoji: nil, in: context)
        let dinner = addReceipt("Restaurant", "2026-04-02", [("my pasta", 40, ["food", "eat out"]),
                                                             ("friend's steak", 30, ["food", "eat out"]), ("shared wine", 30, ["drinks"])])
        XCTAssertEqual(dinner.trip?.persistentModelID, trip.persistentModelID)
        let lines = dinner.lineItems.sorted { $0.position < $1.position }
        try Actions.setSplit([lines[1]], mode: .notMine, in: context)
        try Actions.setSplit([lines[2]], mode: .shared, shares: [SplitShareInput(person: "me", amount: nil, percentage: 50),
                                                                 SplitShareInput(person: "Alex", amount: nil, percentage: 50)], in: context)
        let ledger = ledger()
        // personal = 10 (coffee, before the trip) + 40 + 0 + 15 ; others = 30 + 15
        XCTAssertEqual(ledger.categoryTree().totalSGD, 65)
        XCTAssertEqual(ledger.reimbursementSummary().paidTotal, 45)
        XCTAssertEqual(ledger.categoryTree(trip: trip).totalSGD, 55)
        XCTAssertEqual(ledger.tripSummaries().first?.spend, 55)
        let eatOut = ledger.categoryTree().node(for: category("Eat Out"))!
        XCTAssertEqual(eatOut.totalSGD, 40, "the NOT_MINE steak must not add to the category")
    }

    func testSharedWithoutMeShareCountsFullyAndIsFlagged() {
        let receipt = addReceipt("Bar", "2026-04-03", [("round", 20, [])])
        receipt.lineItems[0].splitMode = .shared
        let item = ledger().items.first!
        XCTAssertTrue(item.splitUnresolved)
        XCTAssertEqual(item.personalSGD, 20)
    }

    func testShareValidation() {
        let receipt = addReceipt("Bar", "2026-04-03", [("round", 20, [])])
        XCTAssertThrowsError(try Actions.setSplit(receipt.lineItems, mode: .shared,
                                                  shares: [SplitShareInput(person: "Alex", amount: nil, percentage: 50)], in: context))
    }

    func testIncomingMoneyStaysOutOfSpendAndMatcher() throws {
        let expense = addTxn("2026-04-05", "TAXI TALLINN", 12)
        let incoming = addTxn("2026-04-06", "FROM ALEX", 45, type: .reimbursement)
        let ledger = ledger()
        XCTAssertFalse(ledger.items.contains { $0.transaction?.persistentModelID == incoming.persistentModelID })
        XCTAssertTrue(ledger.items.contains { $0.transaction?.persistentModelID == expense.persistentModelID })
        XCTAssertEqual(ledger.categoryTree().totalSGD, 12)
    }

    func testReimbursementSettlesAndCheckpointsOnlyWhatItCovered() throws {
        let dinner = addReceipt("Restaurant", "2026-04-02", [("dinner", 90, ["eat out"])])
        try Actions.setSplit(dinner.lineItems, mode: .notMine, in: context)
        let payback = addTxn("2026-04-06", "FROM ALEX", 90, type: .reimbursement)
        var data = ledger().reimbursementSummary()
        XCTAssertTrue(data.settled)
        XCTAssertNotNil(data.pendingCheckpoint)
        XCTAssertTrue(data.recentPaid.isEmpty, "everything is covered by the settlement")
        Actions.recordCheckpointIfNeeded(data, in: context)
        data = ledger().reimbursementSummary()
        XCTAssertNil(data.pendingCheckpoint, "idempotent: the same settled state isn't checkpointed twice")
        XCTAssertEqual(try context.fetch(FetchDescriptor<BalanceCheckpoint>()).count, 1)

        // a new, back-dated item is still new information, even though its date is before the checkpoint
        let lunch = addReceipt("Cafe", "2026-04-01", [("lunch", 12, [])])
        try Actions.setSplit(lunch.lineItems, mode: .notMine, in: context)
        data = ledger().reimbursementSummary()
        XCTAssertEqual(data.outstanding, 12)
        XCTAssertEqual(data.recentPaid.count, 1)
        XCTAssertNotNil(payback)
    }

    func testOverReimbursementIsRejectedAndPartialAmountsCount() throws {
        let dinner = addReceipt("Restaurant", "2026-04-02", [("dinner", 14, [])])
        try Actions.setSplit(dinner.lineItems, mode: .notMine, in: context)
        let payback = addTxn("2026-04-06", "FROM SAM", 30, type: .income)
        XCTAssertEqual(ledger().outstanding(excluding: payback), 14)
        XCTAssertThrowsError(try Actions.classify(payback, as: .reimbursement, reimbursementAmount: 99, in: context))
        try Actions.classify(payback, as: .reimbursement, reimbursementAmount: 14, in: context)
        XCTAssertEqual(ledger().reimbursementSummary().outstanding, 0)
    }

    func testCategoriesSuggestedConfirmedAndGroceryBucket() {
        addReceipt("Cold Storage", "2026-09-03", [("chicken thigh", 60, ["food", "meat"]), ("mystery", 5, ["mystery"])])
        let t = addTxn("2026-09-10", "ICA MAXI", 53.82)
        var ledger = ledger()
        let chicken = ledger.items.first { $0.name == "chicken thigh" }!
        XCTAssertEqual(chicken.category?.name, "Meat")
        XCTAssertEqual(chicken.confidence, .suggested)
        XCTAssertEqual(ledger.items.first { $0.name == "mystery" }!.confidence, .unknown)

        // an explicit pick wins; a receipt-less charge in a category with a Grocery bucket lands in that bucket
        Actions.assignCategory([ledger.items.first { $0.transaction?.persistentModelID == t.persistentModelID }!],
                               to: category("Cooking Ingredients"), ledger: ledger, in: context)
        ledger = self.ledger()
        let ica = ledger.items.first { $0.transaction?.persistentModelID == t.persistentModelID }!
        XCTAssertEqual(ica.category?.name, "Grocery Shopping")
        XCTAssertEqual(ica.confidence, .confirmed)
    }

    func testRememberedItemRuleBecomesASuggestion() {
        addReceipt("Shop", "2026-09-03", [("kyckling", 20, [])])
        var ledger = ledger()
        XCTAssertEqual(ledger.items[0].confidence, .unknown)
        Actions.assignCategory([ledger.items[0]], to: category("Chicken"), remember: true, ledger: ledger, in: context)
        addReceipt("Other shop", "2026-09-05", [("Kyckling", 22, [])])
        ledger = self.ledger()
        let again = ledger.items.first { $0.receipt?.merchant == "Other shop" }!
        XCTAssertEqual(again.category?.name, "Chicken")
        XCTAssertEqual(again.confidence, .suggested)
    }

    func testTransactionSplitAndBreakdown() throws {
        let t = addTxn("2026-09-10", "ICA MAXI", 53.82)
        try Actions.setTransactionSplit(t, myShare: 20, in: context)
        var items = ledger().items(of: t)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].personalSGD ?? 0, 20, accuracy: 0.02)
        XCTAssertEqual(items[0].othersSGD ?? 0, 33.82, accuracy: 0.02)
        XCTAssertThrowsError(try Actions.setTransactionSplit(t, myShare: 99, in: context))

        let settlement = addTxn("2026-09-15", "PAYNOW TO JY", 150)
        try Actions.breakdown(settlement, parts: [BreakdownPart(category: category("Eat Out"), amount: 50, name: nil),
                                                  BreakdownPart(category: category("Transport"), amount: 88, name: nil),
                                                  BreakdownPart(category: category("Souvenirs"), amount: 10, name: nil)], in: context)
        items = ledger().items(of: settlement)
        XCTAssertEqual(items.map(\.name), ["Eat Out", "Transport", "Souvenirs", "Unsorted remainder"])
        XCTAssertEqual(items.reduce(0) { $0 + ($1.personalSGD ?? 0) }, 150, accuracy: 0.01, "same money, not extra")
        XCTAssertThrowsError(try Actions.breakdown(settlement, parts: [BreakdownPart(category: nil, amount: 999, name: nil)], in: context))
    }

    func testReclassifyingDropsTheHandMadeReceipt() throws {
        let t = addTxn("2026-04-07", "TOP UP", 100)
        _ = Actions.manualItem(for: t, in: context)
        XCTAssertEqual(ledger().categoryTree().totalSGD, 100)
        try Actions.classify(t, as: .transferOwnAccount, in: context)
        XCTAssertEqual(ledger().categoryTree().totalSGD, 0)
        XCTAssertEqual(ledger().receipts.count, 0)
    }

    func testBalanceCheckFindsUntrackedMoney() {
        Actions.reconcile(actual: 1000, on: day("2026-09-01"), ledger: ledger(), in: context)
        addTxn("2026-09-20", "CAFE", 10)
        XCTAssertEqual(ledger().currentBalance?.implied, 990)
        let result = Actions.reconcile(actual: 942, on: day("2026-09-23"), ledger: ledger(), in: context)
        XCTAssertEqual(result.gap, 48)
        XCTAssertEqual(ledger().untracked(in: MonthKey(year: 2026, month: 9)), 48)
        XCTAssertEqual(ledger().currentBalance?.implied, 942)
    }

    func testHomeUsualAndProjection() {
        addReceipt("Cold Storage", "2026-08-05", [("chicken", 30, ["food", "meat"]), ("rice", 10, ["food"])])
        addReceipt("MRT", "2026-08-10", [("card", 40, ["transport"])])
        addReceipt("Cold Storage", "2026-07-05", [("chicken", 50, ["food", "meat"])])
        addReceipt("Cold Storage", "2026-09-03", [("chicken thigh", 60, ["food", "meat"])])
        addReceipt("MRT", "2026-09-05", [("card", 20, ["transport"])])
        let home = ledger().home(today: day("2026-09-23"))
        XCTAssertEqual(home.total, 80)
        XCTAssertEqual(home.usualMonths, 2)
        XCTAssertEqual(home.usualTotal ?? 0, 65, accuracy: 0.01)   // (50 + 80) / 2
        XCTAssertEqual(home.categories.map(\.category.name), ["Food", "Transport"])
        XCTAssertEqual(home.categories[0].usual ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(home.paceActual.count, 23)
        XCTAssertEqual(home.previous, MonthKey(year: 2026, month: 8))
        XCTAssertNil(home.next)
        XCTAssertEqual(home.projected, 80 / (23.0 / 30.0), accuracy: 0.05)
        XCTAssertEqual(home.status, .over)
    }

    func testSearchAndTrends() {
        addReceipt("Cold Storage", "2026-09-03", [("chicken thigh", 60, ["food", "meat"]), ("salmon fillet", 30, ["food", "meat"])])
        let found = ledger().search("salmon")
        XCTAssertEqual(found.items.map(\.name), ["salmon fillet"])
        XCTAssertEqual(found.receipts.first?.matched, 1)
        XCTAssertEqual(ledger().search("MEAT").items.count, 2)
        let trends = ledger().trends(rangeMonths: 3, today: day("2026-09-23"))
        XCTAssertEqual(trends.months.map(\.total), [0, 0, 90])
        XCTAssertEqual(trends.weekdays.count, 7)
    }

    func testTripMovesItsReceiptToo() throws {
        let trip = try Actions.createTrip(name: "T", start: nil, end: nil, activate: false, colorHex: nil, emoji: nil, in: context)
        let t = addTxn("2026-09-15", "PAYNOW", 150)
        try Actions.breakdown(t, parts: [BreakdownPart(category: category("Souvenirs"), amount: 150, name: nil)], in: context)
        Actions.assign(t, to: trip, in: context)
        XCTAssertEqual(ledger().tripDetail(trip).summary.spend, 150)
        Actions.delete(t, in: context)
        XCTAssertEqual(ledger().tripDetail(trip).summary.spend, 0)
        XCTAssertEqual(ledger().receipts.count, 0)
    }

    func testDeletingACategoryMovesItemsUp() throws {
        let receipt = addReceipt("Shop", "2026-09-03", [("pork chop", 10, [])])
        receipt.lineItems[0].category = category("Pork")
        XCTAssertEqual(Actions.deleteCategory(category("Pork"), in: context), 1)
        XCTAssertEqual(receipt.lineItems[0].category?.name, "Meat")
        XCTAssertThrowsError(try Actions.createCategory(name: "chicken", parent: category("Meat"), icon: nil, colorHex: nil, in: context))
    }

    /// A shop's history is about the shop: a one-off ICA charge must not inherit "Meat" and look like a decision the user made.
    func testReceiptlessChargeGuessIsBroadAndMarkedAsAGuess() {
        let meat = category("Meat")
        let receipt = addReceipt("ICA Supermarket", "2026-10-09", currency: "SGD", [("Bacon", 3, []), ("Ham", 4, [])])
        for item in receipt.lineItems { item.category = meat }
        try? context.save()
        addTxn("2026-10-08", "ICA SUPERMARKET VAST, UPPSALA", 2.85)
        let drink = ledger().items.first { $0.isVirtual }!
        XCTAssertEqual(drink.confidence, .suggested, "never presented as the user's own choice")
        XCTAssertEqual(drink.category?.kind, .grocery, "broadened to the grocery bucket, not Meat")
        XCTAssertNotNil(drink.suggestionNote)
    }

    /// Pant counts as spending under its own category, and returned bottles come back as a credit.
    func testBottleDepositCountsAsSpendingAndReturnsReduceIt() {
        CategorySeeder.seedIfNeeded(in: context)
        let receipt = addReceipt("ICA", "2026-10-09", currency: "SGD", [("Juice", 3, []), ("Pant", 1, []), ("Pant retur", -0.4, [])])
        for item in receipt.lineItems where item.name.hasPrefix("Pant") { item.isDeposit = true }
        try? context.save()
        let l = ledger()
        XCTAssertEqual(l.categoryTree().totalSGD, 3.6, accuracy: 0.001, "3 + 1 pant - 0.40 returned")
        let pant = Ledger.pantSummary(l.items)
        XCTAssertEqual(pant.paid, 1, accuracy: 0.001)
        XCTAssertEqual(pant.returned, 0.4, accuracy: 0.001)
        XCTAssertEqual(pant.net, 0.6, accuracy: 0.001)
        XCTAssertEqual(l.items.first { $0.isDeposit }?.category?.kind, .deposit)
    }

    /// The reported complaint: moving the drink must take its pant with it.
    func testDepositFollowsItsDrink() {
        CategorySeeder.seedIfNeeded(in: context)
        let draft = ReceiptDraft(merchant: "ICA", merchantOriginal: nil, date: day("2026-10-09"), currency: "SGD", total: 4.6, tax: nil,
                                 items: [ParsedLineItem(name: "Pepsi Max", price: 2.5), ParsedLineItem(name: "Pant", price: 0.5, isDeposit: true),
                                         ParsedLineItem(name: "Bread", price: 2), ParsedLineItem(name: "Pant retur", price: -0.4, isDeposit: true)],
                                 suggestedCategory: nil, ocrConfidence: 1, rawText: "x", sourceImagePath: nil)
        Actions.save(draft, in: context)
        let before = ledger()
        let pepsi = before.items.first { $0.name == "Pepsi Max" }!
        let pant = before.items.first { $0.name == "Pant" }!
        XCTAssertEqual(pant.parentID, pepsi.id)
        XCTAssertNil(before.items.first { $0.name == "Pant retur" }?.parentID, "a returned-bottle credit isn't tied to any drink")
        Actions.assignCategory([pepsi], to: category("Drinks"), ledger: before, in: context)
        let after = ledger()
        XCTAssertEqual(after.items.first { $0.name == "Pant" }?.category?.name, "Drinks")
        XCTAssertEqual(after.items.first { $0.name == "Pant retur" }?.category?.kind, .deposit)
    }

    /// Teaching the app what "Äpple" is must work next time even if the translation comes out differently.
    func testRememberedCategoryMatchesOnThePrintedNameNotTheTranslation() {
        CategorySeeder.seedIfNeeded(in: context)
        let first = addReceipt("ICA Supermarket", "2026-10-09", currency: "SGD", [("Apple R Gala", 2.5, [])])
        first.lineItems[0].originalName = "Apple R Gala ICA"
        try? context.save()
        let apple = ledger().items.first { $0.name == "Apple R Gala" }!
        Actions.assignCategory([apple], to: category("Fruit"), remember: true, ledger: ledger(), in: context)
        let second = addReceipt("ICA Supermarket", "2026-10-16", currency: "SGD", [("Gala apple", 2.6, [])])
        second.lineItems[0].originalName = "Apple R Gala ICA"
        try? context.save()
        let next = ledger().items.first { $0.name == "Gala apple" }!
        XCTAssertEqual(next.category?.name, "Fruit")
        XCTAssertEqual(next.confidence, .suggested, "a remembered choice is offered, never silently confirmed")
    }

    /// Vegetables green, meat red, fruit yellow - inside the same Food category - and a new sub-category gets a free colour.
    func testSubCategoriesHaveTheirOwnColours() throws {
        CategorySeeder.seedIfNeeded(in: context)
        let veg = category("Vegetables"), meat = category("Meat"), fruit = category("Fruit"), food = category("Food")
        XCTAssertEqual(Set([veg, meat, fruit].map(\.effectiveColorHex)).count, 3, "siblings are told apart")
        XCTAssertNotEqual(veg.effectiveColorHex, food.effectiveColorHex)
        let chicken = category("Chicken")
        chicken.colorHex = nil
        XCTAssertEqual(chicken.effectiveColorHex, meat.effectiveColorHex, "no colour of its own: reads as its parent")
        let made = try Actions.createCategory(name: "Herbs", parent: veg, icon: nil, colorHex: nil, in: context)
        let other = try Actions.createCategory(name: "Sprouts", parent: veg, icon: nil, colorHex: nil, in: context)
        XCTAssertNotNil(made.colorHex)
        XCTAssertNotEqual(made.colorHex, other.colorHex)
    }

    /// Renaming "Romantica RosaBand" once names it everywhere: past receipts, and the next one that prints it.
    func testRenamingIsRememberedForTheSamePrintedText() throws {
        let first = addReceipt("ICA", "2026-10-09", currency: "SGD", [("Romantica RosaBand", 6.4, [])])
        let past = addReceipt("ICA", "2026-10-02", currency: "SGD", [("Romantica RosaBand", 6.1, [])])
        let tomato = ledger().items.first { $0.receipt === first }!
        try Actions.rename(tomato, to: "Cherry tomatoes", remember: true, in: context)
        XCTAssertEqual(first.lineItems[0].name, "Cherry tomatoes")
        XCTAssertEqual(first.lineItems[0].originalName, "Romantica RosaBand", "what was printed is kept")
        XCTAssertEqual(past.lineItems[0].name, "Cherry tomatoes", "past items with the same printed text follow")
        let draft = ReceiptDraft(merchant: "ICA", merchantOriginal: nil, date: day("2026-10-16"), currency: "SGD", total: 6.2, tax: nil,
                                 items: [ParsedLineItem(name: "Romantica RosaBand", price: 6.2)], suggestedCategory: nil,
                                 ocrConfidence: 1, rawText: "x", sourceImagePath: nil)
        let next = Actions.save(draft, in: context)
        XCTAssertEqual(next.lineItems[0].name, "Cherry tomatoes", "applied automatically on the next receipt")
        XCTAssertThrowsError(try Actions.rename(tomato, to: "  ", remember: false, in: context))
    }

    func testRenamingWithoutRememberTouchesOnlyThatItem() throws {
        let a = addReceipt("ICA", "2026-10-09", currency: "SGD", [("Mystery thing", 3, [])])
        let b = addReceipt("ICA", "2026-10-10", currency: "SGD", [("Mystery thing", 3, [])])
        try Actions.rename(ledger().items.first { $0.receipt === a }!, to: "Oat drink", remember: false, in: context)
        XCTAssertEqual(a.lineItems[0].name, "Oat drink")
        XCTAssertEqual(b.lineItems[0].name, "Mystery thing")
    }
}
