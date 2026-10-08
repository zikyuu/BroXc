import XCTest
import SwiftData
@testable import ExpenseTracker

final class SupportTests: XCTestCase {
    func testDateParsing() {
        XCTAssertEqual(Dates.parse("2026-08-21"), Dates.day(2026, 8, 21))
        XCTAssertEqual(Dates.parse("21.08.2026"), Dates.day(2026, 8, 21))
        XCTAssertEqual(Dates.parse("07 Sep 2026"), Dates.day(2026, 9, 7))
        XCTAssertEqual(Dates.parse("62026-08-21"), Dates.day(2026, 8, 21))
        XCTAssertNil(Dates.parse("no date here"))
        // a header with no year, read in January, is last year's December
        XCTAssertEqual(Dates.parse("28 Dec", today: Dates.day(2027, 1, 5)!), Dates.day(2026, 12, 28))
    }

    func testHungarianPicksTheCheapestPairing() {
        let pairs = Hungarian.solve([[4, 1, 3], [2, 0, 5], [3, 2, 2]])
        XCTAssertEqual(pairs.reduce(0) { $0 + [[4, 1, 3], [2, 0, 5], [3, 2, 2]][$1.row][$1.column] }, 5)
        XCTAssertEqual(Hungarian.solve([[1, 9], [9, 1], [5, 5]]).count, 2, "more rows than columns: one pair per column")
        XCTAssertEqual(Hungarian.solve([[1, 9, 9], [9, 1, 9]]).count, 2)
        XCTAssertTrue(Hungarian.solve([]).isEmpty)
    }

    func testFuzzyPartialRatio() {
        XCTAssertEqual(Fuzzy.partialRatio("coop", "STORA COOP UPPSALA"), 100)
        XCTAssertGreaterThan(Fuzzy.partialRatio("Pressbyran", "PRESSBYRAN UPPSALA C"), 95)
        // the known false positive that's why category hints use literal substrings, not fuzzy scores:
        // "SL" scored 66.7 against SYSTEMBOLAGET UPPSALA purely by coincidence (same as rapidfuzz did)
        XCTAssertEqual(Fuzzy.partialRatio("SL", "SYSTEMBOLAGET UPPSALA"), 66.67, accuracy: 0.01)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Money.string(1234.5), "$1,234.50")
        XCTAssertEqual(Money.string(-16.5), "−$16.50")
        XCTAssertEqual(Money.string(30, sign: true), "+$30.00")
        XCTAssertEqual(Money.whole(4359.4), "$4,359")
        XCTAssertEqual(Money.string(11.96, estimated: true), "~$11.96")
    }
}

final class YouTripParserTests: XCTestCase {
    func testParsesThreeLineTransactionsAndSharedDateHeaders() {
        let rows = [
            "07 Sep 2026",
            "STORA COOP UPPSALA kr124.59 SEK", "16.50 SGD", "SmartExchange",
            "PRESSBYRAN UPPSALA krio6.00 SEK", "-14.10 SGD", "SmartExchange",
            "06 Sep 2026",
            "SL ACCESS kr300.00 SEK", "39.90 SGD",
        ]
        let parsed = YouTripParser.parse(rows: rows)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0], ParsedTransaction(date: Dates.day(2026, 9, 7), description: "STORA COOP UPPSALA",
                                                    amountSGD: 16.5, localAmount: 124.59, localCurrency: "SEK"))
        XCTAssertEqual(parsed[1].localAmount, 106.0, "OCR read the digits '10' as 'io' inside a currency amount")
        XCTAssertEqual(parsed[1].amountSGD, 14.1)
        XCTAssertEqual(parsed[2].date, Dates.day(2026, 9, 6))
    }
}

final class ReceiptParserTests: XCTestCase {
    private func ocr(_ rows: [(String, Double)]) -> OCRResult {
        OCRResult(lines: rows.enumerated().map { i, row in
            OCRLine(text: row.0, confidence: row.1, box: CGRect(x: 10, y: 40 * Double(i), width: 300, height: 20))
        })
    }

    func testParsesItemsDepositDiscountTotalAndTax() {
        let draft = ReceiptParser.parse(ocr([
            ("STORA COOP", 0.95), ("Date 2026-09-21 SEK", 0.9),
            ("Chicken breast 89.90", 0.9), ("Onions 19.90", 0.9), ("Milk 2 x 15.90", 0.9),
            ("Hygiene napkins 2 for 30:- -11.90", 0.9), ("PANT 2.00", 0.9), ("VAT 12.00", 0.9), ("PAYING 125.80", 0.9),
            ("Card payment 125.80", 0.9),
        ]))
        XCTAssertEqual(draft.merchant, "STORA COOP")
        XCTAssertEqual(draft.currency, "SEK")
        XCTAssertEqual(draft.date, Dates.day(2026, 9, 21))
        XCTAssertEqual(draft.total, 125.80)
        XCTAssertEqual(draft.tax, 12.00)
        XCTAssertEqual(Array(draft.items.map(\.name).prefix(3)), ["Chicken breast", "Onions", "Milk"])
        XCTAssertEqual(draft.items.first { $0.name == "Milk" }?.quantity, 2)
        XCTAssertTrue(draft.items.contains { $0.isDeposit && $0.price == 2.0 })
        XCTAssertFalse(draft.items.contains { $0.name.lowercased().contains("card payment") }, "past the total, nothing more is an item")
    }

    func testDiscountLineFoldsIntoThePreviousItem() {
        let draft = ReceiptParser.parse(ocr([("COOP", 0.9), ("Napkins 41.90", 0.9), ("-11.90", 0.9), ("TOTAL 30.00", 0.9)]))
        XCTAssertEqual(draft.items.count, 1)
        XCTAssertEqual(draft.items[0].originalPrice, 41.90)
        XCTAssertEqual(draft.items[0].discount, 11.90)
        XCTAssertEqual(draft.items[0].price, 30.00, accuracy: 0.001)
    }

    func testUnreadableLinesAreTaggedMystery() {
        let draft = ReceiptParser.parse(ocr([("COOP", 0.9), ("?????? 12.00", 0.2), ("TOTAL 12.00", 0.9)]))
        XCTAssertEqual(draft.items.first?.tags, ["mystery"])
    }

    func testRowGroupingJoinsNameAndPriceOnTheSameLine() {
        let lines = [OCRLine(text: "Onions", confidence: 0.9, box: CGRect(x: 10, y: 100, width: 80, height: 20)),
                     OCRLine(text: "19.90", confidence: 0.5, box: CGRect(x: 300, y: 102, width: 50, height: 20)),
                     OCRLine(text: "Milk 15.90", confidence: 0.9, box: CGRect(x: 10, y: 140, width: 120, height: 20))]
        let rows = RowGrouping.rows(lines)
        XCTAssertEqual(rows.map(\.text), ["Onions 19.90", "Milk 15.90"])
        XCTAssertEqual(rows[0].confidence, 0.5, "a row is only as confident as its weakest box")
    }
}

@MainActor
final class MatcherTests: LedgerTestCase {
    func testMatchesByAmountDateAndNameAndFlagsWeakOnes() {
        let coop = addReceipt("Stora Coop", "2026-09-07", currency: "SEK", [("milk", 124.59, [])])
        let press = addReceipt("Pressbyran", "2026-09-08", currency: "SEK", [("coffee", 106.00, [])])
        coop.merchantOriginal = "Stora Coop"
        let tCoop = addTxn("2026-09-07", "STORA COOP UPPSALA", 16.5, local: 124.59, currency: "SEK")
        let tPress = addTxn("2026-09-08", "PRESSBYRAN UPPSALA C", 14.1, local: 106.00, currency: "SEK")
        let tOther = addTxn("2026-09-08", "SYSTEMBOLAGET", 28, local: 210, currency: "SEK")
        let results = Matcher.run(in: context)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(tCoop.matchedReceipt?.persistentModelID, coop.persistentModelID)
        XCTAssertEqual(tPress.matchedReceipt?.persistentModelID, press.persistentModelID)
        XCTAssertNil(tOther.matchedReceipt, "no receipt: left unmatched, not force-fitted")
        XCTAssertEqual(tCoop.matchStatus, "auto")
        XCTAssertEqual(Matcher.run(in: context).count, 0, "re-running never reconsiders a link already made")
    }

    func testAbsurdPairsAreRejected() {
        addReceipt("Some Cafe", "2026-01-01", currency: "EUR", [("lunch", 50, [])])
        let t = addTxn("2026-09-07", "STORA COOP", 16.5, local: 124.59, currency: "SEK")
        XCTAssertTrue(Matcher.run(in: context).isEmpty)
        XCTAssertNil(t.matchedReceipt)
    }

    func testOddExchangeRateIsFlaggedForReview() {
        for (i, pair) in [(50.0, 75.0), (20.0, 30.0), (30.0, 45.0)].enumerated() {
            addTxn("2026-09-0\(i + 1)", "SHOP \(i)", pair.1, local: pair.0, currency: "EUR")
        }
        let receipt = addReceipt("Cafe Roma", "2026-09-10", currency: "EUR", [("lunch", 50, [])])
        let t = addTxn("2026-09-10", "CAFE ROMA BERLIN", 88, local: 50, currency: "EUR")
        let results = Matcher.run(in: context)
        let mine = results.first { $0.transaction === t }
        XCTAssertNotNil(mine)
        XCTAssertTrue(mine!.needsReview)
        XCTAssertTrue(mine!.note?.contains("off the usual") ?? false)
        XCTAssertEqual(t.matchedReceipt?.persistentModelID, receipt.persistentModelID)
        XCTAssertEqual(t.matchStatus, "needs_review")
    }
}
