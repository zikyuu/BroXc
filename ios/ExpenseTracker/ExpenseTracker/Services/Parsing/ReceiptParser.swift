import Foundation

/// Parser for a Google Translate screenshot of a receipt - the text is already English, so there's no
/// translation step and the keywords are English. Mirrors `receipts/translated_parser.py`.
enum ReceiptParser {
    // best guesses at how Google renders Swedish receipt terms ("ATT BETALA" comes out as "PAYING")
    static let totalKeywords = ["total", "to pay", "paying", "amount due"]
    static let taxKeywords = ["vat", "gst", "tax"]
    static let depositKeywords = ["deposit", "pledge", "pant"]
    static let discountKeywords = ["discount", "discounts", "rebate", "rebates"]
    /// recap lines that restate a figure already captured elsewhere, not real items or totals
    static let skipKeywords = ["subtotal", "sub total", "summary", "summation"]
    /// below this per-row confidence an item is tagged "mystery"
    static let mysteryConfidence = 0.4

    private static let amountPattern = Rx(#"-?\d+[.,]\d{2}\b"#)
    private static let quantityPattern = Rx(#"\b(\d+)\s*[x×]\s*"#, ignoreCase: true)
    // "pcs x 20.95", "0,298 kg x 103,16 SEK/kg": captures the UNIT PRICE only - the leading number is often
    // mangled by translation/OCR, so quantity is inferred as item price / unit price instead.
    private static let breakdownPattern = Rx(#"^\s*(?:[\d.,]+\s*)?[A-Za-z]{1,6}\.?\s*[x×*]\s*(\d+[.,]\d{2})"#, ignoreCase: true)
    private static let currencyPattern = Rx(#"(?<!\w)(SEK|EUR|NOK|DKK|GBP|USD|SGD|KR|€|£|\$)(?!\w)"#, ignoreCase: true)
    // the ISO form isn't word-anchored so a stray OCR character glued on the front still matches
    private static let datePattern = Rx(#"20\d{2}-\d{2}-\d{2}|\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#)

    private static func amount(in text: String) -> Double? {
        amountPattern.all(in: text).last.flatMap { Double($0.text.replacingOccurrences(of: ",", with: ".")) }
    }

    private static func stripAmount(_ text: String) -> String {
        amountPattern.replacingAll(in: text).stripped(of: " -\t")
    }

    /// Whole-word match, so "pant" doesn't fire on "pants" or "vat" on "private".
    private static func matches(_ text: String, _ keywords: [String]) -> Bool {
        let lowered = text.lowercased()
        return keywords.contains { Rx("\\b\(NSRegularExpression.escapedPattern(for: $0))\\b").test(lowered) }
    }

    private static func guessMerchant(_ rows: [String]) -> String? {
        for row in rows {
            let s = row.trimmingCharacters(in: .whitespaces)
            if s.filter(\.isLetter).count >= 3 && !amountPattern.test(s) { return s }
        }
        return nil
    }

    private static func guessCurrency(_ rows: [String]) -> String? {
        for row in rows { if let m = currencyPattern.first(in: row), let g = m.group(1) { return g.uppercased() } }
        return nil
    }

    private static func guessDate(_ rows: [String]) -> Date? {
        for row in rows { if let m = datePattern.first(in: row) { return Dates.parse(m.text) } }
        return nil
    }

    /// Store name off the original-language receipt, kept as printed so it can be compared against the
    /// (untranslated) description YouTrip shows.
    static func originalMerchant(_ ocr: OCRResult) -> String? {
        guessMerchant(RowGrouping.rows(ocr.lines).map(\.text))
    }

    static func parse(_ ocr: OCRResult, sourceImagePath: String? = nil) -> ReceiptDraft {
        let grouped = RowGrouping.rows(ocr.lines)
        let rowTexts = grouped.map(\.text)
        var total: Double?, tax: Double?
        var items: [ParsedLineItem] = []
        var seenTotal = false, inDiscountSection = false

        for (rawText, rowConfidence) in grouped {
            let text = rawText.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || matches(text, skipKeywords) { continue }

            if matches(text, totalKeywords) {
                if let a = amount(in: text) { total = a; seenTotal = true }
                continue
            }
            if matches(text, taxKeywords) {
                if let a = amount(in: text) { tax = a }
                continue
            }
            if seenTotal { continue }   // past the total: payment details, tax table, footer - not more items

            if matches(text, depositKeywords) {
                if let a = amount(in: text) { items.append(ParsedLineItem(name: text, price: a, isDeposit: true)) }
                continue
            }
            if let b = breakdownPattern.first(in: text), !items.isEmpty {
                if let unit = Double((b.group(1) ?? "").replacingOccurrences(of: ",", with: ".")), unit > 0 {
                    let quantity = (items[items.count - 1].price / unit * 1000).rounded() / 1000
                    items[items.count - 1].quantity = quantity
                    // Vision reads "FACIAL NAPKINS 2 41.90" with the count glued to the name; now that it's a
                    // known quantity, drop that stray number from the name
                    let name = items[items.count - 1].name
                    if quantity.rounded() == quantity, let m = Rx(#"\s+(\d+)$"#).first(in: name), Double(m.group(1) ?? "") == quantity {
                        items[items.count - 1].name = String(name[..<m.range.lowerBound])
                    }
                }
                continue
            }
            guard var a = amount(in: text) else {
                // a "DISCOUNTS" header: amounts below are discounts even if OCR dropped the minus sign
                if matches(text, discountKeywords) { inDiscountSection = true }
                continue
            }
            if inDiscountSection { a = -abs(a) }
            let withoutAmount = stripAmount(text)

            if a < 0, !items.isEmpty, matches(text, discountKeywords) || withoutAmount.count <= 3 {
                let previous = items[items.count - 1]
                items[items.count - 1].originalPrice = previous.price
                items[items.count - 1].discount = abs(a)
                items[items.count - 1].price = previous.price - abs(a)
                continue
            }

            var quantity = 1.0, name = withoutAmount
            if let q = quantityPattern.first(in: withoutAmount), let n = Double(q.group(1) ?? "") {
                quantity = n
                name = quantityPattern.replacingFirst(in: withoutAmount)
            }
            name = name.stripped(of: " -\t")
            let unreadable = name.isEmpty || rowConfidence < mysteryConfidence
            items.append(ParsedLineItem(name: name.isEmpty ? text : name, price: a, quantity: quantity, tags: unreadable ? ["mystery"] : []))
        }

        return ReceiptDraft(merchant: guessMerchant(rowTexts), merchantOriginal: nil, date: guessDate(rowTexts),
                            currency: guessCurrency(rowTexts), total: total, tax: tax, items: items,
                            suggestedCategory: (total == nil && items.isEmpty) ? "Mystery" : nil,
                            ocrConfidence: ocr.averageConfidence, rawText: ocr.rawText, sourceImagePath: sourceImagePath)
    }
}
