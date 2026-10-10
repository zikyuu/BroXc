import Foundation

/// Parser for a Google Translate screenshot of a receipt - the text is already English, so there's no
/// translation step and the keywords are English. Mirrors `receipts/translated_parser.py`.
enum ReceiptParser {
    // English as Google renders it ("ATT BETALA" comes out as "PAYING") plus the Swedish as printed, so the same
    // parser reads a translated screenshot or the original photo
    static let totalKeywords = ["total", "to pay", "paying", "amount due", "att betala", "totalt", "summa att betala"]
    static let taxKeywords = ["vat", "gst", "tax", "moms"]
    static let depositKeywords = ["deposit", "pledge", "pant", "pantretur", "pantkvitto", "pantkvittot"]
    static let discountKeywords = ["discount", "discounts", "rebate", "rebates", "rabatt", "rabatter"]
    /// recap lines that restate a figure already captured elsewhere, not real items or totals
    static let skipKeywords = ["subtotal", "sub total", "summary", "summation", "delsumma", "summering", "summa"]
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
        for row in rows {
            guard let m = currencyPattern.first(in: row), let g = m.group(1)?.uppercased() else { continue }
            return g == "KR" ? "SEK" : g   // a bare "kr" on a Swedish receipt is kronor
        }
        return nil
    }

    private static func guessDate(_ rows: [String]) -> Date? {
        for row in rows { if let m = datePattern.first(in: row) { return Dates.parse(m.text) } }
        return nil
    }

    /// A skewed photo reads an item's name and its price as two rows (a name, then a row that is only an amount).
    /// A row with letters but no amount, directly followed by an amount-only row, is one item - join them. The
    /// joined row is only as confident as the weaker of the two. A quantity/weight marker doesn't count as part
    /// of either row ("Potatis" over "0,575kg*10,35Kr/kg 5,95" is still a name over a price).
    static func mergeSplitRows(_ rows: [(text: String, confidence: Double)]) -> [(text: String, confidence: Double)] {
        var merged: [(text: String, confidence: Double)] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            let head = body(row.text), tail = index + 1 < rows.count ? body(rows[index + 1].text) : ""
            if index + 1 < rows.count, !amountPattern.test(head), head.filter(\.isLetter).count >= 3,
               amountPattern.test(tail), stripAmount(tail).filter({ $0.isLetter || $0.isNumber }).count <= 1 {
                merged.append((row.text + " " + rows[index + 1].text, min(row.confidence, rows[index + 1].confidence)))
                index += 2
            } else {
                merged.append(row)
                index += 1
            }
        }
        return merged
    }

    /// "103,16 SEK/kg" is the price per kilo, not part of the item's name.
    private static let perKiloPattern = Rx(#"\d+[.,]\s?\d{2}\s*(?:SEK|kr)?\s*/\s*kg"#, ignoreCase: true)

    // ICA prints how an amount was reached as "2st*16,85" (count x unit price) or "0,575kg*10,35Kr/kg" (weight x
    // price per kilo). Both carry a price that is NOT the line's price, so they're lifted out before looking for
    // the amount; OCR also swaps characters (Cyrillic "г" for "g", "·" for "*"), hence the loose bits.
    private static let countMarker = Rx(#"(\d+)\s*st\s*[*·x×]\s*\d+[.,]\d{2}"#, ignoreCase: true)
    private static let weightMarker = Rx(#"(\d+[.,]\d{3})\s*k\S{1,2}\s*[*·x×]\s*\d+[.,]\d{2}\s*\S{0,5}/\s*\S{0,3}"#, ignoreCase: true)

    /// The quantity a "2st*16,85" / "0,575kg*10,35Kr/kg" marker states, plus the row with the marker removed.
    private static func extractMarker(_ text: String) -> (quantity: Double, rest: String)? {
        if let m = weightMarker.first(in: text), let q = Double((m.group(1) ?? "").replacingOccurrences(of: ",", with: ".")) {
            return (q, weightMarker.replacingFirst(in: text).collapsedWhitespace)
        }
        if let m = countMarker.first(in: text), let q = Double(m.group(1) ?? "") {
            return (q, countMarker.replacingFirst(in: text).collapsedWhitespace)
        }
        return nil
    }

    /// Row text with any quantity/weight marker taken out.
    private static func body(_ text: String) -> String { extractMarker(text)?.rest ?? text }

    /// OCR can space a keyword out ("T otal") - compare with everything but letters dropped.
    private static func looksLikeTotal(_ text: String) -> Bool {
        text.lowercased().filter(\.isLetter).hasPrefix("total") && amountPattern.test(text)
    }

    /// Store name off the original-language receipt, kept as printed so it can be compared against the
    /// (untranslated) description YouTrip shows.
    static func originalMerchant(_ ocr: OCRResult) -> String? {
        let rows = RowGrouping.rows(ocr.lines).map(\.text)
        guard let name = guessMerchant(rows) else { return nil }
        // a stacked logo ("Stora" over "COOP") reads as two rows; "Stora" alone is too vague to match a charge,
        // so a short all-letters row directly below a short first row is the other half of the name
        if let index = rows.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == name }), name.count <= 10, rows.indices.contains(index + 1) {
            let next = rows[index + 1].trimmingCharacters(in: .whitespaces)
            if next.count >= 3, next.count <= 12, next.allSatisfy({ $0.isLetter || $0 == " " }) { return "\(name) \(next)" }
        }
        return name
    }

    static func parse(_ ocr: OCRResult, sourceImagePath: String? = nil, joinStackedLogo: Bool = false) -> ReceiptDraft {
        let grouped = mergeSplitRows(RowGrouping.rows(ocr.lines))
        let rowTexts = grouped.map(\.text)
        var total: Double?, tax: Double?
        var items: [ParsedLineItem] = []
        var seenTotal = false
        // a bare "DISCOUNTS" header makes the next few amounts discounts even if OCR dropped the minus sign; it
        // only reaches a few rows so it can't swallow the real items that follow
        var discountRowsLeft = 0

        for (rawText, rowConfidence) in grouped {
            let text = rawText.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || matches(text, skipKeywords) { continue }

            if matches(text, totalKeywords) || looksLikeTotal(text) {
                if let a = amount(in: text) { total = a; seenTotal = true }
                continue
            }
            if matches(text, taxKeywords) {
                if let a = amount(in: text) { tax = a }
                continue
            }
            if seenTotal { continue }   // past the total: payment details, tax table, footer - not more items

            // "2st*16,85" / "0,575kg*10,35Kr/kg" state a quantity; the price on the row is what's left over
            let marker = extractMarker(text)
            let line = marker?.rest ?? text

            if let marker, line.stripped(of: " -\t*·+").isEmpty, !items.isEmpty {
                items[items.count - 1].quantity = marker.quantity   // marker on its own row belongs to the item above
                continue
            }

            if matches(line, depositKeywords) {
                if var a = amount(in: line) {
                    // bottles handed back are a credit; OCR can split the minus from the figure ("Pant - 12,00")
                    if a > 0, Rx(#"-\s*\d+[.,]\d{2}"#).test(line) { a = -a }
                    let name = stripAmount(line).stripped(of: " -\t*·+")
                    items.append(ParsedLineItem(name: name.isEmpty ? line : name, price: a, quantity: marker?.quantity ?? 1, isDeposit: true))
                }
                continue
            }
            if let b = breakdownPattern.first(in: line), !items.isEmpty {
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
            let isDiscountRow = matches(line, discountKeywords)
            guard var a = amount(in: line) else {
                if isDiscountRow { discountRowsLeft = 3 }
                continue
            }
            // "Rabatt: ... - 10,16": OCR can split the minus from the figure, so a discount row's amount is a
            // reduction whatever sign it came through with
            if isDiscountRow || discountRowsLeft > 0 { a = -abs(a) }
            if discountRowsLeft > 0 { discountRowsLeft -= 1 }
            let withoutAmount = stripAmount(line)

            if a < 0, !items.isEmpty, isDiscountRow || withoutAmount.count <= 3 {
                let previous = items[items.count - 1]
                items[items.count - 1].originalPrice = previous.price
                items[items.count - 1].discount = abs(a)
                items[items.count - 1].price = previous.price - abs(a)
                continue
            }

            var quantity = marker?.quantity ?? 1.0, name = withoutAmount
            if marker == nil, let q = quantityPattern.first(in: withoutAmount), let n = Double(q.group(1) ?? "") {
                quantity = n
                name = quantityPattern.replacingFirst(in: withoutAmount)
            }
            // a leading "*" on ICA marks a campaign price, not part of the name
            name = perKiloPattern.replacingAll(in: name).collapsedWhitespace.stripped(of: " -\t*·+")
            let unreadable = name.isEmpty || rowConfidence < mysteryConfidence
            items.append(ParsedLineItem(name: name.isEmpty ? line : name, price: a, quantity: quantity, tags: unreadable ? ["mystery"] : []))
        }

        return ReceiptDraft(merchant: joinStackedLogo ? (originalMerchant(ocr) ?? guessMerchant(rowTexts)) : guessMerchant(rowTexts), merchantOriginal: nil, date: guessDate(rowTexts),
                            currency: guessCurrency(rowTexts), total: total, tax: tax, items: items,
                            suggestedCategory: (total == nil && items.isEmpty) ? "Mystery" : nil,
                            ocrConfidence: ocr.averageConfidence, rawText: ocr.rawText, sourceImagePath: sourceImagePath)
    }
}
