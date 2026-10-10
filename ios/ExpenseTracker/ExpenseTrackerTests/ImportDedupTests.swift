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
}
