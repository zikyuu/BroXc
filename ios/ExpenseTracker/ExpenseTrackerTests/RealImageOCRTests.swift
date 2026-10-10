import XCTest
import UIKit
import Vision
@testable import ExpenseTracker

/// Runs the real Vision OCR + parsers on your own screenshots, when they're present in the repo folder
/// (they're gitignored personal data, so this skips cleanly anywhere else).
final class RealImageOCRTests: XCTestCase {
    private func repoFile(_ name: String) throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }   // ExpenseTrackerTests -> ExpenseTracker -> ios -> repo
        let file = url.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "\(name) isn't in the repo folder")
        return file
    }

    private func image(_ name: String) throws -> CGImage {
        let file = try repoFile(name)
        return try XCTUnwrap(UIImage(contentsOfFile: file.path)?.cgImage)
    }

    func testYouTripScreenshot() async throws {
        let ocr = try await VisionOCR.recognize(try image("youtrip_screenshot.png"))
        print("=== YOUTRIP OCR ROWS ===")
        for row in RowGrouping.rows(ocr.lines) { print(String(format: "%.2f | %@", row.confidence, row.text)) }
        let parsed = YouTripParser.parse(ocr)
        print("=== PARSED \(parsed.count) TRANSACTIONS ===")
        for t in parsed { print("\(t.date.map { $0.formatted(.iso8601.year().month().day()) } ?? "no date") | \(t.description ?? "-") | \(t.amountSGD.map { String($0) } ?? "-") SGD | local \(t.localAmount.map { String($0) } ?? "-") \(t.localCurrency ?? "")") }
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map(\.amountSGD), [1.33, 7.46])
        XCTAssertEqual(parsed.map(\.localAmount), [10.0, 56.0])
        XCTAssertEqual(parsed.first?.date, Dates.day(2026, 9, 7))
        XCTAssertFalse(parsed.contains { $0.description?.contains("™") ?? false || $0.description?.contains("*") ?? false })
    }

    func testTranslatedReceipt() async throws {
        let ocr = try await VisionOCR.recognize(try image("translated_receipt.png"))
        print("=== RECEIPT OCR ROWS ===")
        for row in RowGrouping.rows(ocr.lines) { print(String(format: "%.2f | %@", row.confidence, row.text)) }
        let draft = ReceiptParser.parse(ocr)
        print("=== PARSED RECEIPT ===")
        print("merchant: \(draft.merchant ?? "-") | date: \(draft.date.map { $0.formatted(.iso8601.year().month().day()) } ?? "-") | currency: \(draft.currency ?? "-") | total: \(draft.total.map { String($0) } ?? "-") | tax: \(draft.tax.map { String($0) } ?? "-") | conf: \(String(format: "%.2f", draft.ocrConfidence ?? 0))")
        for item in draft.items { print("  - \(item.name) x\(item.quantity ?? 1) @ \(item.price)\(item.isDeposit ? " [deposit]" : "")\(item.tags.isEmpty ? "" : " \(item.tags)")") }
        XCTAssertEqual(draft.merchant, "Large coop")
        XCTAssertEqual(draft.total, 124.59)
        XCTAssertEqual(draft.currency, "SEK")
        XCTAssertEqual(draft.date, Dates.day(2026, 8, 21))
        XCTAssertEqual(draft.items.count, 5)
        XCTAssertEqual(draft.items.first?.name, "FACIAL NAPKINS")
        XCTAssertEqual(draft.items.first?.quantity, 2)
        XCTAssertEqual(draft.items.reduce(0) { $0 + $1.price }, 124.59, accuracy: 0.01, "the items add up to the printed total")
    }

    /// The untranslated photo of the same receipt, read straight into a draft (the one-photo flow).
    func testOriginalSwedishPhotoReadsAsAWholeReceipt() async throws {
        let draft = try await ReceiptReader.readOriginalPhoto(try image("receipt.jpg"), sourceImagePath: nil)
        let total = draft.total ?? -1
        print("=== SWEDISH PHOTO PARSED: \(draft.merchant ?? "-") | \(draft.currency ?? "-") | total \(total) | \(draft.items.count) items ===")
        for item in draft.items { print("  - \(item.name) x\(item.quantity ?? 1) @ \(item.price)") }
        XCTAssertEqual(draft.merchant?.lowercased(), "stora coop", "the stacked logo is read as one name")
        XCTAssertEqual(draft.merchantOriginal, draft.merchant)
        XCTAssertEqual(draft.currency, "SEK")
        XCTAssertEqual(draft.date, Dates.day(2026, 8, 21))
        XCTAssertEqual(draft.total, 124.59, "read from 'ATT BETALA ( 5 ARTIKLAR ) 124,59'")
        XCTAssertEqual(draft.items.count, 5, "a skewed photo splits names from prices; they're re-joined")
        XCTAssertEqual(draft.items.reduce(0) { $0 + $1.price }, 124.59, accuracy: 0.01, "the items add up to the printed total")
        XCTAssertFalse(draft.items.contains { $0.name.lowercased().contains("summering") }, "the discount recap isn't an item")
        XCTAssertFalse(draft.items.contains { $0.name.lowercased().contains("kg") }, "price-per-kilo is stripped from names")
    }

    /// A different shop's receipt (ICA, a low-resolution copy): prints "Total" in spaced capitals, weights on a second
    /// line, "Rabatt:" lines under items, and a VAT table and card slip after the total.
    func testICAReceipt() async throws {
        let ocr = try await VisionOCR.recognize(try image("ica_receipt.jpg"), languages: ["sv-SE", "en-US"])
        print("=== ICA ROWS (avg conf \(String(format: "%.2f", ocr.averageConfidence))) ===")
        for row in RowGrouping.rows(ocr.lines) { print(String(format: "%.2f | %@", row.confidence, row.text)) }
        let draft = ReceiptParser.parse(ocr, joinStackedLogo: true)
        for item in draft.items { print("  - \(item.name) x\(item.quantity ?? 1) @ \(item.price)\(item.isDeposit ? " [deposit]" : "")") }

        XCTAssertEqual(draft.merchant, "ICA Supermarket")
        XCTAssertEqual(draft.currency, "SEK")
        XCTAssertEqual(draft.total ?? 0, 395.39, accuracy: 0.001)
        XCTAssertEqual(draft.date, Dates.parse("2026-10-09"))
        // 14 products + 2 bottle-deposit lines; every one of them has to be on the list for the sum to close
        XCTAssertEqual(draft.items.count, 16)
        XCTAssertEqual(draft.items.map(\.price).reduce(0, +), 395.39, accuracy: 0.011, "items must add up to the printed total")
        XCTAssertEqual(draft.items.filter(\.isDeposit).count, 2)
        XCTAssertTrue(draft.items.allSatisfy { $0.price > 0 }, "a discount folds into its item, it isn't an item")
        XCTAssertFalse(draft.items.contains { $0.name.contains("*") || $0.name.contains("kg") }, "quantity markers aren't part of names")
        let potatoes = draft.items.first { $0.name.lowercased().hasPrefix("potatis") }
        XCTAssertEqual(potatoes?.price ?? 0, 5.95, accuracy: 0.001)
        XCTAssertEqual(potatoes?.quantity ?? 0, 0.575, accuracy: 0.001)
        let noodles = draft.items.first { $0.name.lowercased().contains("snabbnudlar") }
        XCTAssertEqual(noodles?.price ?? 0, 40.00, accuracy: 0.001)
        XCTAssertEqual(noodles?.discount ?? 0, 10.16, accuracy: 0.001)
        XCTAssertEqual(noodles?.quantity, 2)
    }
}
