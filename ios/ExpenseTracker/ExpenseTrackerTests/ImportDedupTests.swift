import XCTest
import SwiftData
@testable import ExpenseTracker

/// Importing the same YouTrip list twice (overlapping screenshots) must not double-add charges.
@MainActor
final class ImportDedupTests: LedgerTestCase {
    private func row(_ date: String?, _ description: String, _ sgd: Double, local: Double? = nil, _ currency: String? = nil) -> ParsedTransaction {
        ParsedTransaction(date: date.map(day), description: description, amountSGD: sgd, localAmount: local, localCurrency: currency)
    }
    private func count() -> Int { ledger().transactions.count }

    func testReimportingTheSameScreenshotAddsNothing() {
        let shot = [row("2026-10-07", "STORA COOP UPPSALA", 16.5, local: 124.59, "SEK"), row("2026-10-07", "PRESSBYRAN UPPSALA C", 14.1, local: 106, "SEK")]
        XCTAssertEqual(Actions.saveNew(shot, in: context).added, 2)
        let again = Actions.saveNew(shot, in: context)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.skipped, 2)
        XCTAssertEqual(count(), 2)
    }

    func testOverlappingScreenshotOnlyAddsTheNewDay() {
        _ = Actions.saveNew([row("2026-10-05", "ICA", 20), row("2026-10-07", "TAXI", 12)], in: context)
        let next = Actions.saveNew([row("2026-10-08", "KIOSK", 5), row("2026-10-08", "BUS", 3), row("2026-10-07", "TAXI", 12), row("2026-10-05", "ICA", 20)], in: context)
        XCTAssertEqual(next.added, 2)
        XCTAssertEqual(next.skipped, 2)
        XCTAssertEqual(count(), 4)
    }

    func testARowWhoseDayHeaderScrolledOffStillMatches() {
        _ = Actions.saveNew([row("2026-10-07", "STORA COOP UPPSALA", 16.5, local: 124.59, "SEK")], in: context)
        let result = Actions.saveNew([row(nil, "STORA COOP UPPSALA", 16.5, local: 124.59, "SEK")], in: context)
        XCTAssertEqual(result.added, 0, "no date isn't a different charge")
        XCTAssertEqual(count(), 1)
    }

    func testSlightlyDifferentOCRTextIsTheSameCharge() {
        _ = Actions.saveNew([row("2026-10-07", "UL KOLLEKTIVTR, UPPSALA", 7.46, local: 56, "SEK")], in: context)
        XCTAssertEqual(Actions.saveNew([row("2026-10-07", "UL KOLLEKTIVTR, UPPSALA *", 7.46, local: 56, "SEK")], in: context).added, 0, "a stray symbol")
        XCTAssertEqual(Actions.saveNew([row("2026-10-07", "KOLLEKTIVTR, UPPSALA", 7.46, local: 56, "SEK")], in: context).added, 0, "the start of the name cut off")
        XCTAssertEqual(count(), 1)
    }

    func testGenuineRepeatsAreKeptButNotDoubled() {
        let twoRides = [row("2026-10-07", "UL BUSS", 1.33, local: 10, "SEK"), row("2026-10-07", "UL BUSS", 1.33, local: 10, "SEK")]
        XCTAssertEqual(Actions.saveNew(twoRides, in: context).added, 2, "two real rides")
        XCTAssertEqual(Actions.saveNew(twoRides, in: context).added, 0, "the same screenshot again adds nothing")
        // a third identical row in a later screenshot IS a new ride
        let threeRides = twoRides + [row("2026-10-07", "UL BUSS", 1.33, local: 10, "SEK")]
        XCTAssertEqual(Actions.saveNew(threeRides, in: context).added, 1)
        XCTAssertEqual(count(), 3)
    }

    func testDifferentChargesAreNeverMerged() {
        _ = Actions.saveNew([row("2026-10-07", "ICA MAXI", 20)], in: context)
        XCTAssertEqual(Actions.saveNew([row("2026-10-07", "SYSTEMBOLAGET", 20)], in: context).added, 1, "same amount and day, different shop")
        XCTAssertEqual(Actions.saveNew([row("2026-10-08", "ICA MAXI", 20)], in: context).added, 1, "same shop and amount, different day")
        XCTAssertEqual(Actions.saveNew([row("2026-10-07", "ICA MAXI", 20.5)], in: context).added, 1, "different amount")
        XCTAssertEqual(count(), 4)
    }

    func testReclassifiedChargesStillCountAsSaved() throws {
        _ = Actions.saveNew([row("2026-10-07", "FROM SAM", 30)], in: context)
        try Actions.classify(ledger().transactions[0], as: .reimbursement, in: context)
        XCTAssertEqual(Actions.saveNew([row("2026-10-07", "FROM SAM", 30)], in: context).added, 0)
    }

    /// The YouTrip rows for money sent to people: a letter in a circle instead of a logo, "To name (Mobile no. ending 5455)",
    /// and the note underneath. They're read as payments to a person, with the note kept and the stray letter dropped.
    func testPaymentsToPeopleAreRecognised() {
        let rows = ["18 Sep 2026", "R", "To rayner (Mobile no. ending", "5455)", "spain accoms", "$136.21 SGD",
                    "Top Up", "+$300.00 SGD",
                    "J To junyeun (nus ds) (Mobile no. ending 7122)", "tricount (gothenburg road trip)", "$138.91 SGD",
                    "UL KOLLEKTIVTR, UPPSALA kr90.00 SEK", "$11.70 SGD"]
        let parsed = YouTripParser.parse(rows: rows)
        XCTAssertEqual(parsed.map { $0.payee ?? "-" }, ["rayner", "-", "junyeun (nus ds)", "-"])
        XCTAssertEqual(parsed[0].description, "To rayner · spain accoms")
        XCTAssertEqual(parsed[2].description, "To junyeun (nus ds) · tricount (gothenburg road trip)")
        XCTAssertEqual(parsed.map(\.transactionType), [.expense, .transferOwnAccount, .expense, .expense], "still spending; the top-up isn't")
        XCTAssertEqual(parsed.map { $0.amountSGD ?? 0 }, [136.21, 300, 138.91, 11.70])
        let saved = Actions.saveNew(parsed, in: context)
        XCTAssertEqual(saved.added, 4)
        XCTAssertEqual(try? context.fetch(FetchDescriptor<YouTripTransaction>()).filter { $0.payee != nil }.count, 2)
    }

    /// The real screen: the amount sits beside the FIRST line of a wrapped name, the circle's letter ("R", "J") lands on the amount
    /// row, and the rest of the name and the note come after it - so each payment used to pick up the NEXT one's text.
    func testWrappedPaymentNamesStayWithTheirOwnAmount() {
        let rows = ["1:39 B", "Search merchant, date or amount", "18 Sep 2026", "IIL.PILET.EE, TALLINN €6.00 EUR", "€5.00 EUR", "* SmartExchange™", "$1.46 SGD",
                    "Top Up +$300.00 SGD",
                    "To rayner (Mobile no. ending", "R $136.21 SGD", "5455)", "spain accoms",
                    "To junyeun (nus ds) (Mobile no.", "J $138.91 SGD", "ending 7122)", "tricount (gothenburg road trip)",
                    "To rayner (Mobile no. ending", "R $68.16 SGD", "5455)",
                    "Top Up +$300.00 SGD", "+",
                    "UL KOLLEKTIVTR, UPPSALA kr90.00 SEK", "s SmartExchange™ $11.70 SGD"]
        let parsed = YouTripParser.parse(rows: rows)
        XCTAssertEqual(parsed.map { $0.amountSGD ?? 0 }, [1.46, 300, 136.21, 138.91, 68.16, 300, 11.70])
        XCTAssertEqual(parsed[2].payee, "rayner")
        XCTAssertEqual(parsed[2].description, "To rayner · spain accoms")
        XCTAssertEqual(parsed[3].payee, "junyeun (nus ds)")
        XCTAssertEqual(parsed[3].description, "To junyeun (nus ds) · tricount (gothenburg road trip)")
        XCTAssertEqual(parsed[4].payee, "rayner")
        XCTAssertEqual(parsed[4].description, "To rayner", "no note, and it takes nothing from the next transaction")
        XCTAssertEqual(parsed[5].transactionType, .transferOwnAccount)
        XCTAssertEqual(parsed[6].description, "UL KOLLEKTIVTR, UPPSALA", "no stray icon letter")
    }

    /// The same screen, read by the real OCR (a personal screenshot, skipped where it isn't present).
    func testRealYouTripScreenshotWithPaymentsToPeople() async throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let file = dir.appendingPathComponent("youtrip_peer.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "youtrip_peer.jpg isn't in the repo folder")
        let image = try XCTUnwrap(UIImage(contentsOfFile: file.path)?.cgImage)
        let parsed = try await ReceiptReader.readTransactions(image).transactions
        let peers = parsed.filter { $0.payee != nil }
        XCTAssertEqual(peers.map { $0.amountSGD ?? 0 }, [136.21, 138.91, 68.16])
        XCTAssertEqual(peers.map { $0.payee ?? "" }, ["rayner", "junyeun (nus ds)", "rayner"])
        XCTAssertEqual(peers.map { $0.description ?? "" }, ["To rayner · spain accoms", "To junyeun (nus ds) · tricount (gothenburg road trip)", "To rayner"])
        XCTAssertTrue(parsed.allSatisfy { !($0.description ?? "").contains(" R ") && !($0.description ?? "").hasSuffix(" s") })
    }

    /// PayLah "Cashback" is the government giving money back on a purchase: it lowers spending, and isn't a top-up or income.
    func testCashbackLowersSpending() throws {
        CategorySeeder.seedIfNeeded(in: context)
        let herbs = addReceipt("Herbs", "2026-10-05", currency: "SGD", [("herbs", 3.10, [])])
        herbs.lineItems[0].category = category("Vegetables")
        let cashback = addTxn("2026-10-05", "Cashback", 3.00, type: .cashback)
        cashback.account = .paylah
        try context.save()
        XCTAssertEqual(ledger().categoryTree().totalSGD, 0.10, accuracy: 0.001, "3.10 spent, 3.00 back")
        let item = try XCTUnwrap(ledger().items.first { $0.transaction?.uid == cashback.uid })
        XCTAssertEqual(item.personalSGD ?? 0, -3.00, accuracy: 0.001)
        Actions.assignCategory([item], to: category("Vegetables"), ledger: ledger(), in: context)
        XCTAssertEqual(ledger().categoryTree().node(for: category("Vegetables"))?.totalSGD ?? 0, 0.10, accuracy: 0.001, "filed under the category it came back from")
        XCTAssertEqual(ledger().home(month: nil, today: day("2026-10-20")).total, 0.10, accuracy: 0.001)
        XCTAssertEqual(ledger().movement(since: nil, account: .paylah), 3.00, accuracy: 0.001, "the money did arrive")
    }

    func testPayLahCashbackRowIsRecognised() {
        XCTAssertEqual(YouTripParser.type(for: "Cashback", incoming: true), .cashback)
        XCTAssertEqual(YouTripParser.type(for: "Top up my wallet", incoming: true), .transferOwnAccount)
    }

    /// Importing again fixes payments an earlier read got wrong, instead of skipping them as already saved.
    func testReimportingRepairsWronglyReadPayments() throws {
        let old = ParsedTransaction(date: day("2026-09-18"), description: "5455) spain accoms To junyeun (nus ds) (Mobile no. J", amountSGD: 138.91, transactionType: .expense)
        Actions.saveNew([old], in: context)
        let correct = ParsedTransaction(date: day("2026-09-18"), description: "To junyeun (nus ds) · tricount (gothenburg road trip)", amountSGD: 138.91,
                                        transactionType: .expense, payee: "junyeun (nus ds)")
        let result = Actions.saveNew([correct], in: context)
        XCTAssertEqual(result.added, 0, "same payment, not a new one")
        let stored = try context.fetch(FetchDescriptor<YouTripTransaction>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].transactionDescription, "To junyeun (nus ds) · tricount (gothenburg road trip)")
        XCTAssertEqual(stored[0].payee, "junyeun (nus ds)")
        XCTAssertEqual(Actions.lastRepairCount, 1)
    }
}
