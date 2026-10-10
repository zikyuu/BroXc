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

    func testStackedLogoIsJoinedForTheOriginalMerchant() {
        XCTAssertEqual(ReceiptParser.originalMerchant(ocr([("Stora", 1), ("COOP", 0.5), ("Uppsala, Boländerna", 1)])), "Stora COOP")
        XCTAssertEqual(ReceiptParser.originalMerchant(ocr([("Pressbyran", 1), ("Kvitto: 12345", 1)])), "Pressbyran", "a long single-row name is left alone")
        XCTAssertEqual(ReceiptParser.originalMerchant(ocr([("ICA", 1), ("Maxi Stormarknad Uppsala", 1)])), "ICA", "a long second row isn't part of the logo")
    }

    func testSwedishKeywordsAndDecimalCommas() {
        let draft = ReceiptParser.parse(ocr([("Stora", 1), ("Datum: 2026-08-21", 1), ("Mjölk 15,90", 0.9), ("Pant 2,00", 0.9), ("RABATTER", 1),
                                              ("Kaffe 40,00 -5,00", 0.9), ("SUMMERING RABATTER DETTA KÖP 5,00", 0.9), ("ATT BETALA ( 3 ARTIKLAR ) 52,90", 0.9),
                                              ("Moms 12,00", 0.9), ("KORTKÖP 52,90", 0.9)]))
        XCTAssertEqual(draft.total, 52.90)
        XCTAssertEqual(draft.tax, 12.00)
        XCTAssertEqual(draft.items.first?.name, "Mjölk")
        XCTAssertTrue(draft.items.contains { $0.isDeposit && $0.price == 2.0 })
        XCTAssertFalse(draft.items.contains { $0.name.lowercased().contains("summering") })
    }

    func testNameAndPriceSplitAcrossRowsAreJoined() {
        let rows: [(text: String, confidence: Double)] = [("GODIS LOSVIKt°5", 1), ("30,74", 0.8), ("Datum:", 1), ("2026-08-21 17:08", 1), ("MAX WHITE 33,95", 1)]
        let merged = ReceiptParser.mergeSplitRows(rows)
        XCTAssertEqual(merged.map(\.text), ["GODIS LOSVIKt°5 30,74", "Datum:", "2026-08-21 17:08", "MAX WHITE 33,95"])
        XCTAssertEqual(merged[0].confidence, 0.8, "only as confident as the weaker row")
        let draft = ReceiptParser.parse(ocr([("COOP", 1), ("HARSNODD SAMX 103, 16 SEK/Kg", 1), ("29,90", 1), ("ATT BETALA 29,90", 1)]))
        XCTAssertEqual(draft.items.map(\.name), ["HARSNODD SAMX"])
        XCTAssertEqual(draft.items.first?.price, 29.90)
    }

    func testTranslationKeepsThePrintedNameAlongside() {
        var draft = ReceiptDraft()
        draft.items = [ParsedLineItem(name: "ANSIKTSSERVETTER", price: 41.9), ParsedLineItem(name: "?????", price: 12, tags: ["mystery"]), ParsedLineItem(name: "MJÖLK", price: 15.9)]
        XCTAssertEqual(ReceiptTranslation.texts(draft), ["Ansiktsservetter", "?????", "Mjölk"], "capitals are softened so the translator reads words, not abbreviations")
        let done = ReceiptTranslation.apply(["Facial tissues", "ignored", "Milk"], to: draft)
        XCTAssertEqual(done.items.map(\.name), ["Facial tissues", "?????", "Milk"], "an unreadable line is left alone")
        XCTAssertEqual(done.items.map(\.originalName), ["ANSIKTSSERVETTER", nil, "MJÖLK"])
        // no translator, or a failed one, changes nothing
        XCTAssertEqual(ReceiptTranslation.apply(nil, to: draft).items.map(\.name), ["ANSIKTSSERVETTER", "?????", "MJÖLK"])
        XCTAssertEqual(ReceiptTranslation.apply(["only one"], to: draft).items.map(\.name), ["ANSIKTSSERVETTER", "?????", "MJÖLK"], "a wrong-length answer is ignored, not misaligned")
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

    /// The reported failure: a 395 kr grocery receipt got linked to a $300 top-up on the same day, which then
    /// made every item price on the receipt wrong.
    func testAReceiptNeverLinksToAnUnrelatedChargeJustBecauseOfTheDate() {
        for (i, pair) in [(500.0, 66.0), (300.0, 40.0), (150.0, 20.0)].enumerated() {
            addTxn("2026-10-0\(i + 1)", "SHOP \(i)", pair.1, local: pair.0, currency: "SEK")   // gives SEK a usual rate of about 7.5
        }
        let receipt = addReceipt("ICA Supermarket", "2026-10-09", currency: "SEK", [("groceries", 395.39, [])])
        let topUp = addTxn("2026-10-09", "Top up", 300)
        XCTAssertTrue(Matcher.run(in: context).isEmpty, "same day is not evidence")
        XCTAssertNil(topUp.matchedReceipt)
        // and the right charge (about 52 SGD for 395 kr) is accepted, name or no name
        let real = addTxn("2026-10-09", "ICA SUPERMARKET KISTA", 52.5, local: 395.39, currency: "SEK")
        XCTAssertEqual(Matcher.run(in: context).count, 1)
        XCTAssertEqual(real.matchedReceipt?.persistentModelID, receipt.persistentModelID)
    }

    func testAChargeWithNoLocalAmountIsNeverGuessedAtForAForeignReceipt() {
        for (i, pair) in [(500.0, 66.0), (300.0, 40.0), (150.0, 20.0)].enumerated() { addTxn("2026-10-0\(i + 1)", "SHOP \(i)", pair.1, local: pair.0, currency: "SEK") }
        addReceipt("Some shop", "2026-10-09", currency: "SEK", [("x", 395.39, [])])
        let looksRight = addTxn("2026-10-09", "XYZ", 52.5)   // about right at the usual rate, but nothing proves it
        XCTAssertTrue(Matcher.run(in: context).isEmpty, "no rough conversion: it can only be linked by hand")
        XCTAssertNil(looksRight.matchedReceipt)
    }

    /// $5.97 and $5.95 are different purchases - there is no "close enough" when YouTrip shows the exact amount.
    func testReceiptTotalMustEqualTheChargeNotJustComeCloseToIt() {
        let receipt = addReceipt("Kiosk", "2026-10-09", currency: "SGD", [("snack", 5.97, [])])
        let nearMiss = addTxn("2026-10-09", "KIOSK", 5.95)
        XCTAssertTrue(Matcher.run(in: context).isEmpty)
        XCTAssertNil(nearMiss.matchedReceipt)
        let exact = addTxn("2026-10-09", "KIOSK", 5.97)
        XCTAssertEqual(Matcher.run(in: context).count, 1)
        XCTAssertEqual(exact.matchedReceipt?.persistentModelID, receipt.persistentModelID)
    }

    func testOneCentOfRoundingIsAllowedButNoMore() {
        addReceipt("ICA", "2026-10-09", currency: "SEK", [("a", 395.39, [])])
        let tooFar = addTxn("2026-10-09", "ICA", 52, local: 395.41, currency: "SEK")
        XCTAssertTrue(Matcher.run(in: context).isEmpty)
        XCTAssertNil(tooFar.matchedReceipt)
        let oneCent = addTxn("2026-10-09", "ICA", 52, local: 395.40, currency: "SEK")
        XCTAssertEqual(Matcher.run(in: context).count, 1)
        XCTAssertNotNil(oneCent.matchedReceipt)
    }

    func testTheCurrencyHasToMatchToo() {
        addReceipt("Cafe", "2026-10-09", currency: "EUR", [("a", 50, [])])
        let sek = addTxn("2026-10-09", "CAFE", 6.5, local: 50, currency: "SEK")
        XCTAssertTrue(Matcher.run(in: context).isEmpty, "50 EUR is not 50 SEK")
        XCTAssertNil(sek.matchedReceipt)
    }

    func testEqualAmountsAreToldApartByNameAndFlaggedForReview() {
        let ica = addReceipt("ICA Supermarket", "2026-10-09", currency: "SEK", [("a", 100, [])])
        let coop = addReceipt("Coop", "2026-10-09", currency: "SEK", [("b", 100, [])])
        let tIca = addTxn("2026-10-09", "ICA SUPERMARKET KISTA", 13, local: 100, currency: "SEK")
        let tCoop = addTxn("2026-10-09", "COOP UPPSALA", 13, local: 100, currency: "SEK")
        XCTAssertEqual(Matcher.run(in: context).count, 2)
        XCTAssertEqual(tIca.matchedReceipt?.persistentModelID, ica.persistentModelID)
        XCTAssertEqual(tCoop.matchedReceipt?.persistentModelID, coop.persistentModelID)
        XCTAssertEqual(tIca.matchStatus, "needs_review", "an exact amount that isn't unique is worth a glance")
    }

    func testSameAmountDaysApartNeedsTheNameToAgree() {
        addReceipt("ICA Supermarket", "2026-10-01", currency: "SEK", [("a", 100, [])])
        let stranger = addTxn("2026-10-09", "SYSTEMBOLAGET", 13, local: 100, currency: "SEK")
        XCTAssertTrue(Matcher.run(in: context).isEmpty)
        XCTAssertNil(stranger.matchedReceipt)
        let same = addTxn("2026-10-09", "ICA SUPERMARKET KISTA", 13, local: 100, currency: "SEK")
        let results = Matcher.run(in: context)
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(same.matchedReceipt)
        XCTAssertTrue(results.first?.needsReview ?? false, "8 days apart gets a review flag even with the name agreeing")
    }

    func testAnAbsurdLinkedRateFallsBackToTheUsualRate() throws {
        for (i, pair) in [(500.0, 66.0), (300.0, 40.0), (150.0, 20.0)].enumerated() { addTxn("2026-10-0\(i + 1)", "SHOP \(i)", pair.1, local: pair.0, currency: "SEK") }
        let receipt = addReceipt("ICA", "2026-10-09", currency: "SEK", [("bacon", 16, [])])
        receipt.total = 395.39
        let wrong = addTxn("2026-10-09", "Top up", 300)
        Actions.link(wrong, to: receipt, in: context)   // a human (or a bug) forced a bad link
        let item = ledger().items.first { $0.name == "bacon" }!
        XCTAssertEqual(item.sgdSource, .estimated, "a rate 5x off the usual one isn't trusted")
        XCTAssertEqual(item.priceSGD ?? 0, 16 / 7.5, accuracy: 0.2, "16 kr is about 2 SGD, not 12")
    }

    func testTopUpsAndRefundsAreNotPurchases() {
        XCTAssertEqual(YouTripParser.suggestedType(for: "Top up"), .transferOwnAccount)
        XCTAssertEqual(YouTripParser.suggestedType(for: "TOP-UP via bank transfer"), .transferOwnAccount)
        XCTAssertEqual(YouTripParser.suggestedType(for: "Refund ICA MAXI"), .refund)
        XCTAssertEqual(YouTripParser.suggestedType(for: "Cashback"), .income)
        XCTAssertEqual(YouTripParser.suggestedType(for: "ICA SUPERMARKET KISTA"), .expense)
        XCTAssertEqual(YouTripParser.suggestedType(for: nil), .expense)
        let parsed = YouTripParser.parse(rows: ["09 Oct 2026", "Top up", "300.00 SGD", "ICA KISTA kr395.39 SEK", "52.50 SGD"])
        XCTAssertEqual(parsed.map(\.transactionType), [.transferOwnAccount, .expense])
        let saved = Actions.saveNew(parsed, in: context)
        XCTAssertEqual(saved.added, 2)
        XCTAssertEqual(ledger().categoryTree().totalSGD, 52.5, "the top-up isn't spending")
    }

    func testGreenPlusRowsAreMoneyIn() {
        let rows = ["09 Oct 2026", "Allowance", "+300.00 SGD", "From Mum", "+ $50.00 SGD", "ICA KISTA kr395.39 SEK", "52.50 SGD", "Refund ICA", "+S$12.00 SGD"]
        let parsed = YouTripParser.parse(rows: rows)
        XCTAssertEqual(parsed.map(\.transactionType), [.other, .other, .expense, .refund])
        XCTAssertEqual(parsed.map { $0.amountSGD ?? 0 }, [300, 50, 52.5, 12])
        XCTAssertEqual(parsed[0].description, "Allowance", "the plus sign isn't left in the description")
        XCTAssertEqual(YouTripParser.parse(rows: ["Top up", "+100.00 SGD"]).first?.transactionType, .transferOwnAccount, "wording still wins when there is any")
    }

    func testMoneyInCanBeFiledUnderACustomCategory() throws {
        let t = addTxn("2026-10-09", "From Mum", 300, type: .other)
        XCTAssertEqual(Actions.addMoneyInLabel(" Allowance ", in: context), "Allowance")
        XCTAssertEqual(Actions.addMoneyInLabel("allowance", in: context), "Allowance", "no duplicates")
        try Actions.classify(t, as: .income, label: "Allowance", in: context)
        XCTAssertEqual(t.transactionType, .income)
        XCTAssertEqual(t.incomeLabel, "Allowance")
        try Actions.classify(t, as: .transferOwnAccount, in: context)
        XCTAssertNil(t.incomeLabel, "the label goes when it's no longer income")
    }

    /// The reported bug: the phone's clock and YouTrip's search box got glued onto the first charge's name.
    func testScreenFurnitureIsNotPartOfAMerchantName() {
        let rows = ["2:58", "Search merchant, date or amount", "09 Oct 2026", "ICA SUPERMARKET KISTA kr395.39 SEK", "50.85 SGD",
                    "2:588 Search merchant, date or amount", "HMSHost Arlanda kr100.00 SEK", "13.00 SGD"]
        let parsed = YouTripParser.parse(rows: rows)
        XCTAssertEqual(parsed.map(\.description), ["ICA SUPERMARKET KISTA", "HMSHost Arlanda"])
        // and with no date header at all, the search box still never leaks in
        let noHeader = YouTripParser.parse(rows: ["Search merchant, date or amount", "SL ACCESS kr300.00 SEK", "39.90 SGD"])
        XCTAssertEqual(noHeader.first?.description, "SL ACCESS")
    }
}
