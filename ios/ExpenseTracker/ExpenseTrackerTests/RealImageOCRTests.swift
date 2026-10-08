import XCTest
import UIKit
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
}
