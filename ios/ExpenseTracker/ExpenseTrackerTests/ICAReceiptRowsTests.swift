import XCTest
@testable import ExpenseTracker

/// The same ICA receipt as the phone read it: "Total" came out as "lotal" and the weight line has a space before "/kg".
final class ICAReceiptRowsTests: XCTestCase {
    func testReceiptReadingMistakesDontBreakTheItemList() {
        let rows = ["ICA", "Supermarket", "*Väst*", "TEL, 018-461800", "FLOGSTA CENTRUM", "752 72 UPPSALA", "Saljare: 57207 Kassa: 05 Nr: 6772", "Datum: 2026-10-09 Tid: 10:22",
            "Ref. 4400149405013658041009264", "Bacon tärnad 15,99", "Champinjon 2st*16,85 33,70", "Grönkålsblad ICA 38,64", "lu! Lök Nät ICA 15,26",
            "Lantskinka ex. rökt 2st*20,23 40,46", "*Max 2st*15,99 31,98", "Rabatt: Superklipp P 2f20kr -11,98", "+ Pant 2st*2,00 4,00", "Mellanmjölk 1,5% 20,01",
            "Potatis lösvikt", "0,575kg*10,35Kг /kg 5,95", "Provencalsk Sallad 28,50", "Romantica RosaBand 49,68", "*Snabbnudlar Carbon 2st*25,08 50,16",
            "Rabatt: Snabbnudlar 2f40kr -10,16", "Sunny Drange 20,72", "+ Pant 2,00", "Agg 15-pack frigde 40,60", "Apple R Gala ICA", "0,710kg*28,00kr/kg 19,88",
            "lotal 395,39 Kr", "Moms% Moms Netto Brutto", "6,00 22,38 373,01 395,39", "Erhällen rabatt: 22,14", "Mottaget Kontokort 395,39", "Totalt SEK 395,39"]
        let lines = rows.enumerated().map { OCRLine(text: $0.element, confidence: 1, box: CGRect(x: 0, y: CGFloat($0.offset) * 40, width: 300, height: 20)) }
        let draft = ReceiptParser.parse(OCRResult(lines: lines), joinStackedLogo: true)
        XCTAssertEqual(draft.total ?? 0, 395.39, accuracy: 0.001)
        XCTAssertEqual(draft.items.count, 16, "14 products + 2 pant lines, and nothing from the footer: \(draft.items.map(\.name))")
        XCTAssertEqual(draft.items.map(\.price).reduce(0, +), 395.39, accuracy: 0.011)
        let potatoes = draft.items.first { $0.name.lowercased().hasPrefix("potatis") }
        XCTAssertEqual(potatoes?.price ?? 0, 5.95, accuracy: 0.001, "the weight line with a stray space still belongs to the potatoes")
        XCTAssertEqual(draft.items.first { $0.name.hasPrefix("Mellanmj") }?.quantity, 1)
        XCTAssertTrue(draft.items.contains { $0.name.hasPrefix("Snabbnudlar") && abs($0.price - 40) < 0.001 })
    }

    /// The second photo: "15,99" came through as ",99", "28,50" as "28 3,50", and the weight line had spaces inside it.
    /// The printed total is the checksum that says what those prices must have been.
    func testUnreadablePricesAreWorkedOutFromTheTotal() {
        let rows = ["ICA", "Supermarket", "Datun: 2026-10-09 Tid: 10:22", "Bacon tärnad", ",99", "Champinjon 2st*16,85 33,70", "Grönkålsblad ICA 38,64",
            "Gul Lök Nät ICA 15,26", "Lantskinka ex. rökt 2st*20,23 40,46", "*Max 2st*15,99 31,98", "Rabatt: Superklipp P 2f20kr -11,98",
            "+ Pant 2st*2,00 4,00", "Mellanmjölk 1,5% 20,01", "Potatis lösvikt", "0,575kg*10, 35K r/kg 5,95", "Provencalsk Sallad 28 3,50",
            "Romantica RosaBand 49,68", "*Snabbnudlar Carbon 2st*25,08 50,16", "Rabatt: Snabbnudlar 2f40kr -10,16", "Sunny Orange 20,72", "+ Pant 2,00",
            "Agg 15-pack frigắe 40,60", "Apple R Gala ICA 0,710kg*28,00Kr/kg 19,88", "Total 395,39 Kr", "Moms% Moms Netto Brutto"]
        let lines = rows.enumerated().map { OCRLine(text: $0.element, confidence: 1, box: CGRect(x: 0, y: CGFloat($0.offset) * 40, width: 300, height: 20)) }
        let draft = ReceiptParser.parse(OCRResult(lines: lines), joinStackedLogo: true)
        XCTAssertEqual(draft.items.count, 16, "\(draft.items.map(\.name))")
        XCTAssertEqual(draft.items.map(\.price).reduce(0, +), 395.39, accuracy: 0.011)
        XCTAssertEqual(draft.items.first { $0.name.hasPrefix("Bacon") }?.price ?? 0, 15.99, accuracy: 0.001, "worked out from the total")
        XCTAssertEqual(draft.items.first { $0.name.hasPrefix("Provencalsk") }?.price ?? 0, 28.50, accuracy: 0.001)
        XCTAssertEqual(draft.items.first { $0.name.hasPrefix("Provencalsk") }?.name, "Provencalsk Sallad", "the stray 28 isn't left in the name")
        XCTAssertEqual(draft.items.first { $0.name.hasPrefix("Potatis") }?.quantity ?? 0, 0.575, accuracy: 0.001)
        XCTAssertEqual(draft.repairs.count, 2)
    }

    /// Never guess: if nothing makes the lines add up, a doubtful price is left alone.
    func testNothingIsInventedWhenTheTotalDoesNotClose() {
        let rows = ["ICA", "Bacon tärnad", ",99", "Bread 10,00", "Total 50,99 Kr"]
        let lines = rows.enumerated().map { OCRLine(text: $0.element, confidence: 1, box: CGRect(x: 0, y: CGFloat($0.offset) * 40, width: 300, height: 20)) }
        let draft = ReceiptParser.parse(OCRResult(lines: lines))
        XCTAssertEqual(draft.items.first { $0.name.hasPrefix("Bacon") }?.price ?? 0, 40.99, accuracy: 0.001, "what the total leaves, and it ends in .99 like the readable cents")
        let impossible = ReceiptParser.parse(OCRResult(lines: ["ICA", "Bacon tärnad", ",99", "Bread 10,00", "Total 50,50 Kr"].enumerated().map {
            OCRLine(text: $0.element, confidence: 1, box: CGRect(x: 0, y: CGFloat($0.offset) * 40, width: 300, height: 20)) }))
        XCTAssertEqual(impossible.items.first { $0.name.hasPrefix("Bacon") }?.price ?? 0, 0.99, accuracy: 0.001, "40.50 can't end in .99: left as read")
        XCTAssertTrue(impossible.repairs.isEmpty)
    }

    /// Two imperfect readings of the same receipt: each has what the other lacks, and the total says which to believe.
    func testTwoReadingsCombineIntoAFullReceipt() {
        func item(_ name: String, _ price: Double, deposit: Bool = false) -> ParsedLineItem { ParsedLineItem(name: name, price: price, isDeposit: deposit) }
        let first = [item("Champinjon", 33.70), item("Provencalsk Sallad", 3.50), item("Snabbnudlar Carbon", 0.01 + 39.99 - 40 + 0)]   // noodles garbled to 0
        let second = [item("Bacon tärnad", 15.99), item("Champinjon", 33.70), item("Provencalsk Sallad", 28.50), item("Snabbnudlar Carbon", 40)]
        let total = 15.99 + 33.70 + 28.50 + 40
        let entries = ReceiptMerge.combine(base: first, total: total, others: [second])
        XCTAssertEqual(entries.map(\.item.name), ["Bacon tärnad", "Champinjon", "Provencalsk Sallad", "Snabbnudlar Carbon"], "the missing line goes in where it belongs")
        XCTAssertEqual(entries.map(\.item.price).reduce(0, +), total, accuracy: 0.011)
        XCTAssertEqual(entries.first?.base, nil, "it came from the other reading")
        XCTAssertEqual(entries.first { $0.item.name.hasPrefix("Prov") }?.item.price, 28.50)
    }

    func testAReadingIsNeverTakenUnlessItGetsCloserToTheTotal() {
        func item(_ name: String, _ price: Double) -> ParsedLineItem { ParsedLineItem(name: name, price: price) }
        let good = [item("Bacon", 15.99), item("Milk", 20.01)]
        let wrong = [item("Bacon", 99.99), item("Cheese", 7.00)]
        let entries = ReceiptMerge.combine(base: good, total: 36.00, others: [wrong])
        XCTAssertEqual(entries.map(\.item.name), ["Bacon", "Milk"], "already adds up: left alone")
        XCTAssertEqual(entries.map(\.item.price), [15.99, 20.01])
        let short = ReceiptMerge.combine(base: [item("Bacon", 15.99)], total: 36.00, others: [[item("Cheese", 99), item("Milk", 20.01)]])
        XCTAssertEqual(short.map(\.item.name), ["Bacon", "Milk"], "a line that would overshoot is not added")
    }

    /// The reported bug: a re-read took a receipt that was 40.99 kr short and made it 5.95 kr OVER. The saved receipt had the
    /// potatoes under a junk name, so the re-read's "Potatis" looked new, and adding it one-by-one fooled the check.
    func testRereadNeverOvershootsTheTotal() {
        func item(_ name: String, _ price: Double) -> ParsedLineItem { ParsedLineItem(name: name, price: price) }
        let saved = [item("Champinjon", 33.70), item("0,575kg*10, 35K r/kg", 5.95), item("Provencalsk Sallad", 3.50), item("Romantica RosaBand", 49.68)]
        let reading = [item("Bacon tärnad", 15.99), item("Champinjon", 33.70), item("Potatis lösvikt", 5.95), item("Provencalsk Sallad", 28.50), item("Romantica RosaBand", 49.68)]
        let total = 15.99 + 33.70 + 5.95 + 28.50 + 49.68   // the saved junk-named line is the potatoes
        let entries = ReceiptMerge.combine(base: saved, total: total, others: [reading])
        XCTAssertEqual(entries.map(\.item.price).reduce(0, +), total, accuracy: 0.011, "adds up exactly, not over")
        XCTAssertEqual(entries.count, 5, "bacon was added, the potatoes weren't added a second time")
        XCTAssertEqual(entries.first { $0.item.name.hasPrefix("Prov") }?.item.price, 28.50)
    }
}
