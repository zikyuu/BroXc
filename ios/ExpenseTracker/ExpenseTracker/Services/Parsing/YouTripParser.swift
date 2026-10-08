import Foundation
import CoreGraphics

/// YouTrip transaction-list screenshot parser. Real screenshots lay each transaction out across stacked
/// lines, not one flat row: a date header (once per day, shared by every transaction below it), then per
/// transaction a merchant-plus-local-currency line, a converted SGD-amount line, and a "SmartExchange"
/// caption. This walks rows top to bottom as a small state machine. Mirrors `transactions/youtrip_parser.py`.
enum YouTripParser {
    private static let sgdAmount = Rx(#"-?\d+[.,]\d{2}\s*SGD\b"#, ignoreCase: true)
    private static let anyAmount = Rx(#"-?\d+[.,]\d{2}"#)
    private static let datePattern = Rx(#"\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*(?:\s+\d{2,4})?\b"#, ignoreCase: true)
    private static let skipKeywords = ["smartexchange"]
    private static let localAmount = Rx(#"kr([A-Za-z0-9]+\.\d{2})\s*SEK"#, ignoreCase: true)
    // what the merchant actually charged, shown next to the SGD figure: "kr10.00 SEK", "€50.00 EUR"
    private static let localCharge = Rx(#"(?:kr|€|£|\$)?\s*(\d+[.,]\d{2})\s*(SEK|EUR|NOK|DKK|GBP|USD)\b"#, ignoreCase: true)

    private static let lookalikes: [Character: Character] = [
        "i": "1", "I": "1", "l": "1", "L": "1", "o": "0", "O": "0", "s": "5", "S": "5", "b": "8", "B": "8",
    ]

    /// OCR sometimes reads a digit as a similar-looking letter inside a currency amount. A "kr<...>.NN SEK"
    /// substring can only ever be a number, so those letters are translated back within that substring only -
    /// a real merchant name elsewhere in the row can't get mangled by this.
    static func fixLocalAmount(_ text: String) -> String {
        localAmount.replacingAll(in: text) { m in
            "kr" + String((m.group(1) ?? "").map { lookalikes[$0] ?? $0 }) + " SEK"
        }
    }

    static func extractSGD(_ text: String) -> Double? {
        guard let m = sgdAmount.first(in: text), let n = anyAmount.first(in: m.text) else { return nil }
        return Double(n.text.replacingOccurrences(of: ",", with: ".")).map(abs)
    }

    /// Moves the local-currency charge out of the description into its own value, so the matcher can
    /// compare it against a receipt total.
    static func splitLocalCharge(_ description: String?) -> (amount: Double?, currency: String?, description: String?) {
        guard let description, let m = localCharge.first(in: description),
              let amount = Double((m.group(1) ?? "").replacingOccurrences(of: ",", with: ".")) else { return (nil, nil, description) }
        let remainder = String(description[..<m.range.lowerBound]) + " " + String(description[m.range.upperBound...])
        let cleaned = remainder.collapsedWhitespace.stripped(of: " -,$\t")
        return (amount, (m.group(2) ?? "").uppercased(), cleaned.isEmpty ? nil : cleaned)
    }

    /// The state machine over already-grouped rows (so it can be tested without an image).
    static func parse(rows: [String]) -> [ParsedTransaction] {
        var result: [ParsedTransaction] = []
        var currentDate: String?
        var pending: [String] = []

        for original in rows {
            let row = fixLocalAmount(original)
            let dateMatch = datePattern.first(in: row)
            let sgd = extractSGD(row)

            if dateMatch != nil && sgd == nil { currentDate = dateMatch!.text; continue }

            if let sgd {
                var leftover = sgdAmount.replacingAll(in: row)
                for keyword in skipKeywords { leftover = Rx(keyword, ignoreCase: true).replacingAll(in: leftover) }
                leftover = Rx(#"[*•™®©]"#).replacingAll(in: leftover)   // the SmartExchange bullet and trademark mark leave stray symbols behind
                leftover = leftover.collapsedWhitespace.stripped(of: " -,$\t")
                if !leftover.isEmpty { pending.append(leftover) }
                let joined = pending.joined(separator: " ").stripped(of: " -,\t")
                let split = splitLocalCharge(joined.isEmpty ? nil : joined)
                result.append(ParsedTransaction(date: Dates.parse(currentDate), description: split.description,
                                                amountSGD: sgd, localAmount: split.amount, localCurrency: split.currency))
                pending = []
                continue
            }
            if skipKeywords.contains(where: { row.lowercased().contains($0) }) { continue }
            pending.append(row.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    static func parse(_ ocr: OCRResult) -> [ParsedTransaction] {
        parse(rows: RowGrouping.rows(ocr.lines).map(\.text))
    }
}

/// OCR + parse, the two live paths.
enum ReceiptReader {
    /// Reads a translated receipt screenshot; if the original-language photo is also given, reads its store
    /// name too, so the matcher can compare against YouTrip's untranslated description.
    static func readReceipt(translated: CGImage, original: CGImage?, sourceImagePath: String?) async throws -> ReceiptDraft {
        var draft = ReceiptParser.parse(try await VisionOCR.recognize(translated, languages: ["en-US"]), sourceImagePath: sourceImagePath)
        if let original {
            let ocr = try await VisionOCR.recognize(original, languages: ["sv-SE", "en-US"])
            draft.merchantOriginal = ReceiptParser.originalMerchant(ocr)
        }
        return draft
    }

    static func readTransactions(_ image: CGImage) async throws -> [ParsedTransaction] {
        YouTripParser.parse(try await VisionOCR.recognize(image, languages: ["en-US"]))
    }
}
