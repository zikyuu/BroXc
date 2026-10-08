import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class LedgerTests: LedgerTestCase {
    func testSeededTree() {
        let meat = category("Meat")
        XCTAssertEqual(meat.path, ["Food", "Cooking Ingredients", "Meat"])
        XCTAssertEqual(meat.effectiveColorHex, category("Food").colorHex)
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
}
