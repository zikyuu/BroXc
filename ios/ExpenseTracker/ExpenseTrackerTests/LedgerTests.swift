import XCTest
import SwiftUI
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

    /// The reported gap: a receipt whose lines don't add up to its printed total used to look fine - nothing compared them.
    func testReceiptWhoseLinesDontAddUpIsFlaggedAndCanBeFixed() throws {
        let receipt = addReceipt("ICA", "2026-10-09", currency: "SEK", [("Bacon", 15.99, []), ("Noodles", 40, [])])
        XCTAssertNil(receipt.unexplainedAmount, "lines equal the total")
        receipt.total = 395.39
        receipt.lineItems.first { $0.name == "Noodles" }!.price = 0.01
        XCTAssertEqual(receipt.unexplainedAmount ?? 0, 379.39, accuracy: 0.001, "a missed 379.39 kr shows up as the difference")
        let missing = try Actions.addLine(to: receipt, name: "Missed item", price: 379.39, in: context)
        XCTAssertNil(receipt.unexplainedAmount, "adding the missing line closes the gap")
        XCTAssertEqual(missing.position, 2)
        let typed = addReceipt("Cafe", "2026-10-09", itemised: false, [("coffee", 3, [])])
        typed.total = 99
        XCTAssertNil(typed.unexplainedAmount, "a hand-made receipt has nothing to check against")
    }

    /// DBS, PayLah and YouTrip each keep their own balance; a YouTrip purchase never moves the DBS one.
    func testEachAccountHasItsOwnBalance() {
        let first = ledger()
        Actions.reconcile(actual: 1000, on: day("2026-10-01"), account: .dbs, ledger: first, in: context)
        Actions.reconcile(actual: 200, on: day("2026-10-01"), account: .youtrip, ledger: first, in: context)
        addTxn("2026-10-05", "ICA", 30, local: 230, currency: "SEK")
        let after = ledger()
        XCTAssertEqual(after.currentBalance(for: .dbs)?.implied, 1000, "spending on YouTrip doesn't touch DBS")
        XCTAssertEqual(after.currentBalance(for: .youtrip)?.implied ?? 0, 170, accuracy: 0.001)
        XCTAssertNil(after.currentBalance(for: .paylah), "no balance entered yet")
        // a second DBS check has no DBS records to compare, so it never invents "untracked spending"
        let result = Actions.reconcile(actual: 800, on: day("2026-10-08"), account: .dbs, ledger: after, in: context)
        XCTAssertEqual(result.gap, 0)
        XCTAssertEqual(ledger().currentBalance(for: .dbs)?.implied, 800)
        XCTAssertEqual(ledger().untracked(in: MonthKey(day("2026-10-08"))), 0)
    }

    /// A Tricount settlement paid by PayNow: itemise your share by hand, and the items travel with the trip.
    func testTricountPaymentCanBeItemisedAndAssignedToATrip() throws {
        let trip = try Actions.createTrip(name: "Paris", start: day("2026-10-01"), end: day("2026-10-06"), activate: false, colorHex: nil, emoji: nil, in: context)
        let t = addTxn("2026-10-06", "PayNow to Friend paris tricount", 139.63)
        t.account = .dbs; t.isOutflow = true
        try Actions.breakdown(t, parts: [BreakdownPart(category: category("Eat Out"), amount: 90, name: "Dinners"),
                                         BreakdownPart(category: category("Activities"), amount: 40, name: "Louvre tickets")], in: context)
        Actions.assign(t, to: trip, in: context)
        let items = ledger().items(of: t).sorted { $0.price > $1.price }
        XCTAssertEqual(items.map(\.name), ["Dinners", "Louvre tickets", "Unsorted remainder"])
        XCTAssertEqual(items.map(\.price).reduce(0, +), 139.63, accuracy: 0.001, "the same money, not extra")
        XCTAssertTrue(items.allSatisfy { $0.trip?.persistentModelID == trip.persistentModelID }, "every item is in the trip")
        XCTAssertEqual(ledger().tripSummaries().first { $0.trip === trip }?.spend ?? 0, 139.63, accuracy: 0.01)
    }

    /// Items filed straight under Meat (nothing in Chicken or Pork yet) are Meat's own, called "Other meat" if there is a
    /// deeper breakdown too - never a mystery "Others".
    func testItemsDirectlyInACategoryAreNamedAfterIt() throws {
        let meat = category("Meat")
        let r = addReceipt("ICA", "2026-10-09", currency: "SGD", [("Bacon", 3, []), ("Ham", 4, []), ("Chicken thighs", 5, [])])
        for item in r.lineItems { item.category = item.name == "Chicken thighs" ? category("Chicken") : meat }
        try? context.save()
        let node = try XCTUnwrap(ledger().categoryTree().node(for: meat))
        XCTAssertEqual(node.children.filter(\.isUnsorted).map(\.name), ["Other meat"])
        XCTAssertEqual(node.children.first { $0.isUnsorted }?.totalSGD ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(node.children.first { $0.category?.name == "Chicken" }?.totalSGD ?? 0, 5, accuracy: 0.001)
    }

    /// The sample data is for looking around: it must leave a real trip alone and come out cleanly.
    func testSampleDataIsKeptApartFromRealDataAndRemovable() throws {
        let real = try Actions.createTrip(name: "Real trip", start: day("2026-10-01"), end: day("2026-10-20"), activate: true, colorHex: nil, emoji: nil, in: context)
        let mine = addReceipt("My shop", "2026-10-05", currency: "SGD", [("my item", 12, [])])
        let charge = addTxn("2026-10-05", "MY SHOP", 12)
        DemoData.load(into: context)
        XCTAssertTrue(DemoData.isLoaded(in: context))
        XCTAssertTrue(real.isActive, "loading samples doesn't switch off the trip you're really on")
        let demoReceipts = try context.fetch(FetchDescriptor<Receipt>()).filter(\.isDemo)
        XCTAssertTrue(demoReceipts.allSatisfy { $0.trip?.persistentModelID != real.persistentModelID }, "no sample item lands in your trip")
        DemoData.remove(from: context)
        XCTAssertFalse(DemoData.isLoaded(in: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Receipt>()).map(\.persistentModelID), [mine.persistentModelID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<YouTripTransaction>()).map(\.persistentModelID), [charge.persistentModelID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.name), ["Real trip"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<BalanceReconciliation>()).isEmpty)
    }

    /// With history, this month's pace shows: ahead of usual in one category, behind in another, and a projection.
    func testSampleMonthHasShapeForTheChart() throws {
        DemoData.load(into: context)
        let home = ledger().home(month: nil, today: Date())
        XCTAssertGreaterThan(home.usualMonths, 0)
        let shopping = try XCTUnwrap(home.categories.first { $0.category.name == "Shopping" })
        let health = try XCTUnwrap(home.categories.first { $0.category.name == "Health" })
        let fraction = max(home.elapsedFraction, 0.25)
        XCTAssertGreaterThan(shopping.actual / ((shopping.usual ?? 1) * fraction), 1.2, "ahead of the usual pace")
        XCTAssertLessThan(health.actual / ((health.usual ?? 1) * fraction), 0.6, "well behind it")
    }

    /// Export, wipe, import: the same receipts, links, categories, trips, names and balances come back.
    func testBackupRoundTrip() throws {
        let trip = try Actions.createTrip(name: "Paris", start: day("2026-10-01"), end: day("2026-10-06"), activate: false, colorHex: "#ff8a75", emoji: "🗼", in: context)
        let receipt = addReceipt("ICA", "2026-10-05", currency: "SEK", [("Bacon", 15.99, []), ("Milk", 20.01, [])])
        receipt.trip = trip
        let bacon = receipt.lineItems.first { $0.name == "Bacon" }!
        bacon.category = category("Meat"); bacon.originalName = "Bacon tärnad"
        let charge = addTxn("2026-10-05", "ICA SUPERMARKET", 4.6, local: 36, currency: "SEK")
        charge.matchedReceipt = receipt; charge.matchStatus = "approved"; charge.trip = trip
        Actions.learn("bacon tärnad", category("Meat"), in: context)
        let account = try Actions.addAccount(name: "Savings", kind: .savings, number: "111-22222-3", in: context)
        Actions.reconcile(actual: 500, on: day("2026-10-01"), account: Account(rawValue: account.key), ledger: ledger(), in: context)
        try context.save()
        let data = try DataExport.backupData(from: context)

        Actions.eraseEverything(in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Receipt>()).isEmpty)
        try DataExport.restore(data, into: context)

        let receipts = try context.fetch(FetchDescriptor<Receipt>())
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].lineItems.count, 2)
        XCTAssertEqual(receipts[0].lineItems.first { $0.name == "Bacon" }?.category?.path, ["Food", "Cooking Ingredients", "Meat"])
        XCTAssertEqual(receipts[0].lineItems.first { $0.name == "Bacon" }?.originalName, "Bacon tärnad")
        XCTAssertEqual(receipts[0].trip?.name, "Paris")
        let transactions = try context.fetch(FetchDescriptor<YouTripTransaction>())
        XCTAssertEqual(transactions.first?.matchedReceipt?.persistentModelID, receipts[0].persistentModelID, "the link survives")
        XCTAssertEqual(transactions.first?.trip?.name, "Paris")
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItemRule>()).count, 1)
        XCTAssertEqual(ledger().currentBalance(for: Account(rawValue: account.key))?.implied ?? 0, 500, accuracy: 0.001)
        XCTAssertTrue(ledger().accounts.contains { $0.name == "Savings" && $0.number == "111-22222-3" })
        XCTAssertThrowsError(try DataExport.restore(Data("nope".utf8), into: context), "a random file isn't a backup")
    }

    // MARK: reimbursement log (the Tallinn trip from real life)

    private func tallinn() throws -> (trip: Trip, costs: [SharedCost]) {
        let trip = try Actions.createTrip(name: "Tallinn", start: day("2026-09-10"), end: day("2026-09-18"), activate: false, colorHex: nil, emoji: nil, in: context)
        let lines: [(String, Double, String)] = [("medieval dinner tips", 1.74, "junyuen"), ("lingonberry drink", 4.41, "junyuen"), ("medieval dinner", 14.21, "junyuen"),
            ("water", 0.44, "junyuen"), ("dumplings lunch", 11.82, "rayner"), ("bruto cookies", 6.53, "junyuen"), ("ice cream", 1.69, "junyuen"),
            ("bolt ride back", 12.92, "melden"), ("water", 0.24, "junyuen")]
        let costs = try lines.map { try Actions.addSharedCost(title: $0.0, amount: $0.1, date: nil, remark: nil, person: $0.2, category: category("Eat Out"), trip: trip, in: context) }
        // two things paid for others on the card
        let magnet = addReceipt("Souvenirs", "2026-09-12", currency: "SGD", [("magnet", 4.43, [])])
        magnet.trip = trip
        try Actions.setSplit(magnet.lineItems, mode: .notMine, in: context)
        let lunch = addReceipt("Pancakes", "2026-09-13", currency: "SGD", [("pancake lunch", 12.13, [])])
        lunch.trip = trip
        try Actions.setSplit(lunch.lineItems, mode: .shared, shares: [SplitShareInput(person: "me", amount: nil, percentage: 20), SplitShareInput(person: "others", amount: nil, percentage: 80)], in: context)
        return (trip, costs)
    }

    private func pay(_ date: String, _ who: String, _ amount: Double, trip: Trip) {
        let t = addTxn(date, "To \(who)", amount)
        t.payee = who; t.trip = trip
    }

    func testReimbursementLogTalliesTheTallinnTrip() throws {
        let (trip, _) = try tallinn()
        pay("2026-09-18", "rayner", 11.42, trip: trip); pay("2026-09-18", "junyuen", 28.45, trip: trip)
        let log = ledger().tripLog(trip)
        XCTAssertEqual(log.owed, 54.00, accuracy: 0.001)
        XCTAssertEqual(log.owedToYou, 14.13, accuracy: 0.011, "magnet 4.43 + 80% of the pancake lunch")
        XCTAssertEqual(log.net, 39.87, accuracy: 0.011)
        XCTAssertEqual(log.paid, 39.87, accuracy: 0.001)
        XCTAssertTrue(log.balanced)
        XCTAssertEqual(log.unaccounted, 0, accuracy: 0.011)
        // what counts as spending: what you owe, plus your own 20% of the lunch; the payments themselves aren't spending again
        let spend = ledger().tripSummaries().first { $0.trip === trip }?.spend ?? 0
        XCTAssertEqual(spend, 54.00 + 2.43, accuracy: 0.02)
        // and the 14.13 you fronted is cancelled against what you owe, so nothing is left "owed to you"
        XCTAssertEqual(ledger().reimbursementSummary().outstanding, 0, accuracy: 0.011)
    }

    func testPayingMoreThanLoggedShowsWhatIsUnaccountedFor() throws {
        let (trip, costs) = try tallinn()
        pay("2026-09-18", "rayner", 11.42, trip: trip); pay("2026-09-18", "junyuen", 28.45, trip: trip)
        for cost in costs.suffix(4) { Actions.deleteSharedCost(cost, in: context) }       // only part of the Tricount logged so far
        let log = ledger().tripLog(trip)
        XCTAssertFalse(log.balanced)
        XCTAssertGreaterThan(log.unaccounted, 5)
        let unaccounted = try XCTUnwrap(ledger().items.first { $0.id.hasPrefix("unacc-") })
        XCTAssertEqual(unaccounted.personalSGD ?? 0, log.unaccounted, accuracy: 0.001, "still visible as unsorted spending: the money isn't hidden")
        // moving it into a category logs it as a cost, which closes the gap
        Actions.assignCategory([unaccounted], to: category("Eat Out"), ledger: ledger(), in: context)
        XCTAssertTrue(ledger().tripLog(trip).balanced)
        XCTAssertNil(ledger().items.first { $0.id.hasPrefix("unacc-") })
    }

    func testCostsLoggedBeforeAnyPaymentJustWait() throws {
        let (trip, _) = try tallinn()
        let log = ledger().tripLog(trip)
        XCTAssertEqual(log.stillToPay, 39.87, accuracy: 0.011)
        XCTAssertEqual(log.paid, 0)
        XCTAssertFalse(log.balanced)
        XCTAssertNil(ledger().items.first { $0.id.hasPrefix("unacc-") }, "no payment yet, so nothing unaccounted")
    }

    func testRoundedPaymentsAreWithinLeeway() throws {
        let (trip, _) = try tallinn()
        pay("2026-09-18", "rayner", 11.40, trip: trip); pay("2026-09-18", "junyuen", 28.40, trip: trip)   // 7 cents short across two transfers
        XCTAssertTrue(ledger().tripLog(trip).balanced, "10 cents allowed per payment")
        let (_, _) = (0, 0)
        let t = addTxn("2026-09-19", "To melden", 1.00); t.payee = "melden"; t.trip = trip
        XCTAssertFalse(ledger().tripLog(trip).balanced, "a whole extra dollar is not rounding")
    }

    func testBackupKeepsSharedCosts() throws {
        let (trip, _) = try tallinn()
        let data = try DataExport.backupData(from: context)
        Actions.eraseEverything(in: context)
        try DataExport.restore(data, into: context)
        let restored = try context.fetch(FetchDescriptor<Trip>()).first { $0.name == "Tallinn" }
        XCTAssertEqual(restored.map { ledger().tripLog($0).owed } ?? 0, 54.00, accuracy: 0.001)
        XCTAssertNotNil(trip)
    }

    /// The log is laid out by day of the trip, and a cost can be moved to another day.
    func testReimbursementLogIsLaidOutByTripDayAndCostsMoveBetweenDays() throws {
        let trip = try Actions.createTrip(name: "Tallinn", start: day("2026-09-18"), end: day("2026-09-21"), activate: false, colorHex: nil, emoji: nil, in: context)
        let water = try Actions.addSharedCost(title: "water", amount: 0.44, date: day("2026-09-19"), remark: nil, person: nil, category: nil, trip: trip, in: context)
        let stray = try Actions.addSharedCost(title: "lunch", amount: 5, date: day("2026-09-30"), remark: nil, person: nil, category: nil, trip: trip, in: context)
        let costs = ledger().tripLog(trip).costs
        let slots = TripDays.slots(trip: trip, costs: costs)
        XCTAssertEqual(slots.first, day("2026-09-30"), "newest first, and a day outside the trip still gets a section")
        XCTAssertEqual(Set(slots), Set(["2026-09-18", "2026-09-19", "2026-09-20", "2026-09-21", "2026-09-30"].map(day)))
        XCTAssertEqual(TripDays.dayNumber(day("2026-09-19"), trip: trip), 2)
        XCTAssertNil(TripDays.dayNumber(day("2026-09-30"), trip: trip).flatMap { $0 > 4 ? nil : $0 }, "after the trip's last day")
        Actions.moveSharedCost(uid: stray.uid, to: day("2026-09-20"), in: context)
        XCTAssertEqual(stray.date, day("2026-09-20"))
        XCTAssertEqual(TripDays.slots(trip: trip, costs: ledger().tripLog(trip).costs).count, 4, "the stray day disappears once nothing is on it")
        Actions.moveSharedCost(uid: water.uid, to: nil, in: context)
        XCTAssertNil(water.date, "dropped on \"no day yet\"")
        XCTAssertEqual(ledger().tripLog(trip).owed, 5.44, accuracy: 0.001, "moving between days never changes what you owe")
    }

    /// "Fully reimbursed!" vs "$x still owed" for what you fronted on a trip.
    func testStillOwedOnATripCountsWhatYouOweAndWhatCameBack() throws {
        let trip = try Actions.createTrip(name: "Paris", start: day("2026-10-01"), end: day("2026-10-06"), activate: false, colorHex: nil, emoji: nil, in: context)
        let r = addReceipt("Dinner", "2026-10-03", currency: "SGD", [("dinner", 40, [])])
        r.trip = trip
        try Actions.setSplit(r.lineItems, mode: .notMine, in: context)
        XCTAssertEqual(ledger().tripStillOwed(trip, fronted: 40), 40, accuracy: 0.001, "nobody has paid anything back")
        try Actions.addSharedCost(title: "taxi", amount: 12, date: nil, remark: nil, person: nil, category: nil, trip: trip, in: context)
        XCTAssertEqual(ledger().tripStillOwed(trip, fronted: 40), 28, accuracy: 0.001, "what you owe cancels against it")
        let back = addTxn("2026-10-05", "FROM SAM", 28, type: .reimbursement)
        back.trip = nil
        XCTAssertEqual(ledger().tripStillOwed(trip, fronted: 40), 0, accuracy: 0.001, "paid back during the trip: fully reimbursed")
    }

    /// Fixing a misread receipt by hand: edit a price, delete a double-read line (and its pant), waive a few cents of difference.
    func testEditingDeletingAndWaivingOnAMisreadReceipt() throws {
        let receipt = addReceipt("ICA", "2026-10-09", currency: "SEK", [("Bacon", 15.99, []), ("Bacon", 15.99, []), ("Milk", 20.01, [])])
        receipt.total = 36.41   // the printed total is 0.41 more than the lines
        try context.save()
        XCTAssertEqual(receipt.unexplainedAmount ?? 0, 0.41 - 15.99, accuracy: 0.011, "the double-read line pushes the lines over the total")
        let dup = ledger().items(of: receipt).filter { $0.name == "Bacon" }[1]
        XCTAssertEqual(Actions.deleteLines([dup], in: context), 1)
        XCTAssertEqual(ledger().items(of: receipt).count, 2)
        XCTAssertEqual(receipt.unexplainedAmount ?? 0, 0.41, accuracy: 0.011, "now 0.41 short")
        try Actions.setLinePrice(ledger().items(of: receipt).first { $0.name == "Milk" }!, to: 20.30, in: context)
        XCTAssertEqual(receipt.unexplainedAmount ?? 0, 0.12, accuracy: 0.011)
        Actions.waiveGap(receipt, in: context)
        XCTAssertNil(receipt.unexplainedAmount, "ignored: no warning")
        try Actions.addLine(to: receipt, name: "Gum", price: 5, in: context)
        XCTAssertNotNil(receipt.unexplainedAmount, "if the difference changes, the warning comes back")
        Actions.unwaiveGap(receipt, in: context)
        XCTAssertNotNil(receipt.unexplainedAmount)
    }

    func testDeletingADrinkTakesItsPantWithIt() throws {
        let draft = ReceiptDraft(merchant: "ICA", merchantOriginal: nil, date: day("2026-10-09"), currency: "SGD", total: 3, tax: nil,
                                 items: [ParsedLineItem(name: "Max", price: 2.5), ParsedLineItem(name: "Pant", price: 0.5, isDeposit: true)],
                                 suggestedCategory: nil, ocrConfidence: 1, rawText: "x", sourceImagePath: nil)
        let receipt = Actions.save(draft, in: context)
        let max = ledger().items(of: receipt).first { $0.name == "Max" }!
        XCTAssertEqual(Actions.deleteLines([max], in: context), 2)
        XCTAssertTrue(receipt.lineItems.isEmpty)
    }

    func testBackupKeepsAWaivedDifference() throws {
        let receipt = addReceipt("ICA", "2026-10-09", currency: "SEK", [("Bacon", 15.99, [])])
        receipt.total = 16.40
        Actions.waiveGap(receipt, in: context)
        let data = try DataExport.backupData(from: context)
        Actions.eraseEverything(in: context)
        try DataExport.restore(data, into: context)
        XCTAssertNil(try context.fetch(FetchDescriptor<Receipt>()).first?.unexplainedAmount)
    }

    /// Every icon the app refers to must really be in the asset catalog, or a category would draw blank.
    func testEveryCategoryIconAndMascotImageExists() throws {
        let bundle = Bundle(for: LedgerTestCase.self).bundleIdentifier == nil ? Bundle.main : Bundle(identifier: "com.shianne.expensetracker") ?? Bundle.main
        var slugs = Set(CategoryArt.forName.values)
        for group in CategoryArt.picker { slugs.formUnion(group.slugs) }
        for slug in slugs { XCTAssertNotNil(UIImage(named: "cat-\(slug)", in: bundle, compatibleWith: nil), "missing icon cat-\(slug)") }
        for name in ["hero", "expr-happy", "expr-thinking", "expr-excited", "expr-sad", "expr-tired"] {
            XCTAssertNotNil(UIImage(named: "mascot-\(name)", in: bundle, compatibleWith: nil), "missing mascot-\(name)")
        }
    }

    /// The theme migration recolours untouched defaults and icons, and leaves what the user chose alone.
    func testThemeMigrationKeepsUserChoices() throws {
        let food = category("Food"), meat = category("Meat"), veg = category("Vegetables")
        food.colorHex = Category.legacyTopLevelColors[0]; food.icon = "🍴"          // untouched old defaults
        meat.colorHex = "#123456"; meat.icon = "🥩"                                    // the user's own colour (the icon is still the default)
        veg.icon = "🥦"                                                                // the user's own icon
        UserDefaults.standard.removeObject(forKey: "broxcThemeApplied")
        CategorySeeder.applyBroXcThemeOnce(in: context)
        XCTAssertEqual(food.colorHex, Category.topLevelColors[0])
        XCTAssertEqual(food.icon, CategoryArt.symbol(slug: "food"))
        XCTAssertEqual(meat.colorHex, "#123456", "a colour the user picked stays")
        XCTAssertEqual(meat.icon, CategoryArt.symbol(slug: "meat"))
        XCTAssertEqual(veg.icon, "🥦", "an icon the user picked stays")
        UserDefaults.standard.removeObject(forKey: "broxcThemeApplied")
    }

    func testAnyColourCanBeStoredAsHex() {
        XCTAssertEqual(Color(hex: "#8fbf7a").hexString.lowercased(), "#8fbf7a")
    }

    /// A grocery run with lines in Meat and Vegetables: the row shows what they share, or the kind of visit you set, never a receipt icon.
    func testReceiptRowShowsTheKindOfVisit() throws {
        CategorySeeder.ensureBeautyOnce(in: context)
        let r = addReceipt("ICA Supermarket", "2026-10-09", currency: "SGD", [("Bacon", 3, []), ("Carrots", 2, [])])
        r.lineItems.first { $0.name == "Bacon" }!.category = category("Meat")
        r.lineItems.first { $0.name == "Carrots" }!.category = category("Vegetables")
        try context.save()
        let before = ledger().activityFeed().first { $0.receipt === r }
        XCTAssertEqual(before?.category?.category?.name, "Cooking Ingredients", "the lowest category both lines sit under")
        Actions.setVisitCategory(r, category("Grocery Shopping"), in: context)
        let after = ledger().activityFeed().first { $0.receipt === r }
        XCTAssertEqual(after?.category?.category?.name, "Grocery Shopping")
        XCTAssertEqual(after?.category?.confidence, .confirmed)
        XCTAssertEqual(r.lineItems.first { $0.name == "Bacon" }?.category?.name, "Meat", "the lines keep their own categories")
        // the same store next time starts as a suggestion
        let next = addReceipt("ICA Supermarket", "2026-10-16", currency: "SGD", [("Milk", 2, [])])
        let entry = ledger().activityFeed().first { $0.receipt === next }
        XCTAssertEqual(entry?.category?.category?.name, "Grocery Shopping")
        XCTAssertEqual(entry?.category?.confidence, .suggested)
        XCTAssertNotNil(category("Beauty").parent, "Beauty sits under Shopping")
    }

    func testTripScenesMapFromOldEmoji() {
        XCTAssertEqual(TripArt.key("🏖️"), "trip-beach")
        XCTAssertEqual(TripArt.key("trip-train"), "trip-airport", "a cover from the earlier set maps to the nearest new one")
        XCTAssertEqual(TripArt.key(nil), "trip-castle")
        for art in TripArt.all { XCTAssertNotNil(UIImage(named: art.key, in: Bundle(identifier: "com.shianne.expensetracker") ?? .main, compatibleWith: nil), art.key) }
    }

    /// Grocery Shopping is a store type: it sits at the top level, not inside Cooking Ingredients, and an older tree is moved once.
    func testGroceryShoppingIsTopLevelAndAnOldTreeIsMoved() throws {
        XCTAssertNil(category("Grocery Shopping").parent, "fresh trees put it at the top level")
        XCTAssertFalse(category("Cooking Ingredients").children.contains { $0.kind == .grocery })
        let grocery = category("Grocery Shopping")
        grocery.parent = category("Cooking Ingredients")       // an install from before the change
        try context.save()
        UserDefaults.standard.removeObject(forKey: "groceryTopLevel")
        CategorySeeder.moveGroceryToTopLevelOnce(in: context)
        XCTAssertNil(grocery.parent)
        XCTAssertNotNil(grocery.colorHex)
        UserDefaults.standard.removeObject(forKey: "groceryTopLevel")
    }

    /// A total budget judges the month on its own, ahead of the category budgets and your usual month.
    func testTotalBudgetDrivesThePaceStatus() {
        addReceipt("Shop", "2026-10-05", currency: "SGD", [("stuff", 300, [])])
        let today = day("2026-10-15")
        let over = Ledger(receipts: ledger().receipts, transactions: [], categories: ledger().categories, trips: [], totalBudget: 400).home(month: nil, today: today)
        XCTAssertEqual(over.totalBudget, 400)
        XCTAssertEqual(over.status, .over, "300 in 15 of 31 days projects to about 620, well past a 400 budget")
        let fine = Ledger(receipts: ledger().receipts, transactions: [], categories: ledger().categories, trips: [], totalBudget: 1000).home(month: nil, today: today)
        XCTAssertEqual(fine.status, .good)
        XCTAssertNil(ledger().home(month: nil, today: today).totalBudget, "no budget set")
    }

    func testBudgetTotalFallsBackToTheCategoryBudgets() {
        addReceipt("Cold Storage", "2026-10-03", [("chicken", 60, ["food", "meat"])])
        addReceipt("Mall", "2026-10-04", [("shirt", 40, ["shopping"])])
        let today = day("2026-10-15")
        XCTAssertNil(ledger().home(month: nil, today: today).budgetTotal, "nothing budgeted")
        category("Food").budgetSGD = 300
        category("Shopping").budgetSGD = 100
        try? context.save()
        XCTAssertEqual(ledger().home(month: nil, today: today).budgetTotal, 400, "the category budgets added up")
        let set = Ledger(receipts: ledger().receipts, transactions: [], categories: ledger().categories, trips: [], totalBudget: 900).home(month: nil, today: today)
        XCTAssertEqual(set.budgetTotal, 900, "a total you set wins")
    }

    func testTheFirstMonthNoteGoesAwayOnceThereIsAFullEarlierMonth() {
        addReceipt("Cold Storage", "2026-10-03", [("chicken", 60, ["food", "meat"])])
        let today = day("2026-10-15")
        XCTAssertEqual(ledger().home(month: nil, today: today).usualMonths, 0, "first month: no usual yet")
        addReceipt("Cold Storage", "2026-09-10", [("chicken", 50, ["food", "meat"])])
        XCTAssertGreaterThan(ledger().home(month: nil, today: today).usualMonths, 0, "a full earlier month makes a usual")
    }
}
