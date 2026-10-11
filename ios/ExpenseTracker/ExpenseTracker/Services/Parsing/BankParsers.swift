import Foundation
import CoreGraphics

/// Which app a transaction-list screenshot came from, worked out from what's on it - so one "add screenshot" button
/// serves all three.
enum ScreenshotKind {
    case youtrip, paylah, dbs

    static func detect(_ rows: [String]) -> ScreenshotKind {
        // DBS prints the sign inside the amount: "SGD - 200.00", "SGD + 850.00"
        if rows.contains(where: { Rx(#"SGD\s*[+\-−–]\s*\d"#, ignoreCase: true).test($0) }) { return .dbs }
        // PayLah prints "SGD 16.00" with no sign, under a "History / PayLah!" title
        if rows.prefix(12).contains(where: { $0.lowercased().contains("paylah") }) { return .paylah }
        if rows.contains(where: { Rx(#"^\s*SGD\s*\d[\d,]*\.\d{2}\s*>?\s*$"#, ignoreCase: true).test($0) }) && !rows.contains(where: { $0.lowercased().contains("smartexchange") }) { return .paylah }
        return .youtrip
    }
}

/// DBS / POSB account history (what PayNow goes through). Each entry is a few lines of description, a detail line
/// ("Digital Wallet • Funds Transfer • ITR") and then "SGD - 16.00" or "SGD + 850.00", under a dated header.
enum DBSParser {
    private static let amountRow = Rx(#"^\s*SGD\s*([+\-−–])\s*(\d[\d,]*[.,]\d{2})\s*$"#, ignoreCase: true)
    private static let dateHeader = Rx(#"^\s*(?:[A-Za-z]+,?\s+)?\d{1,2}\s+[A-Za-z]{3,}\s+\d{4}\s*$"#)
    private static let reference = Rx(#"^[A-Z]{1,3}\d{10,}$"#)
    /// An account-to-account transfer: "TRF FT000000MB00000000 123-45678-9:IB note".
    private static let transferRef = Rx(#"^TRF\s+\S+\s+(\d{3}-\d{4,6}-\d{1,3})\s*:?\s*(.*)$"#, ignoreCase: true)
    private static let detailMarks: [Character] = ["•", "·", "‧", "∙"]
    private static let payNow = Rx(#"PayNow\s+Transfer\s+\d+\s+(To|From):\s*(.*)$"#, ignoreCase: true)

    private static func compact(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The account the screenshot is of: DBS prints its name and number in the header ("Everyday Account", "123-45678-9").
    static func accountHint(rows: [String]) -> (name: String?, number: String?) {
        let numberPattern = Rx(#"\b\d{3}-\d{4,6}-\d{1,3}\b"#)
        for (index, row) in rows.enumerated() {
            guard let m = numberPattern.first(in: row) else { continue }
            // the nearest row above the number with real words in it (not the back arrow, not the drop-down caret)
            var name: String?
            for j in stride(from: index - 1, through: max(0, index - 3), by: -1) where j >= 0 {
                let cleaned = Rx(#"\s+\S$"#).replacingFirst(in: rows[j]).trimmingCharacters(in: CharacterSet(charactersIn: "<> ‹›").union(.whitespaces))
                if cleaned.filter(\.isLetter).count >= 3 { name = cleaned; break }
            }
            return (name?.isEmpty == false ? name : nil, m.text)
        }
        return (nil, nil)
    }

    static func parse(rows: [String]) -> [ParsedTransaction] {
        var result: [ParsedTransaction] = []
        var date: Date?
        var lines: [String] = []

        for original in rows {
            let row = original.trimmingCharacters(in: .whitespaces)
            if dateHeader.test(row), let parsed = Dates.parse(row) { date = parsed; lines = []; continue }
            if row.lowercased().hasPrefix("updated on") { lines = []; continue }
            if let m = amountRow.first(in: row), let digits = m.group(2) {
                let amount = Double(digits.replacingOccurrences(of: ",", with: "")) ?? 0
                if let entry = entry(lines: lines, outgoing: m.group(1) == "-" || m.group(1) == "−" || m.group(1) == "–", amount: amount, date: date) { result.append(entry) }
                lines = []
                continue
            }
            lines.append(row)
        }
        return result
    }

    private static func entry(lines: [String], outgoing: Bool, amount: Double, date: Date?) -> ParsedTransaction? {
        // the description is the lines above the amount, without the detail line, reference numbers, or the logo's
        // caption repeating the name ("You Trip" beside a "youtrip" picture)
        var names: [String] = []
        for line in lines where !line.contains(where: { detailMarks.contains($0) }) && !reference.test(line) && !line.isEmpty {
            if names.contains(where: { compact($0) == compact(line) }) { continue }
            names.append(line)
        }
        // a long description wraps mid-number ("420-" / "06909-0"): rejoin without the space
        let name = names.reduce("") { $0.isEmpty ? $1 : ($0.hasSuffix("-") ? $0 + $1 : $0 + " " + $1) }
        guard !name.isEmpty else { return nil }
        let lowered = name.lowercased()

        var type: TransactionType
        var description = name
        if lowered.contains("paylah") || compact(name).hasPrefix("youtrip") {
            type = .transferOwnAccount   // moving your own money between accounts: neither spending nor income
            description = compact(name).hasPrefix("youtrip") ? "YouTrip top-up" : "Top-up to PayLah"
        } else if let m = transferRef.first(in: name), let number = m.group(1) {
            // to or from another account by number: your own if that number is one of your accounts (decided on saving)
            let note = (m.group(2) ?? "").trimmingCharacters(in: .whitespaces)
            description = (outgoing ? "Transfer to " : "Transfer from ") + number + (note.isEmpty ? "" : " (\(note))")
            type = .transferOwnAccount
        } else if let m = payNow.first(in: name), let who = m.group(2) {
            let toSomeone = (m.group(1) ?? "").lowercased() == "to"
            description = (toSomeone ? "PayNow to " : "PayNow from ") + who
            type = toSomeone ? .expense : YouTripParser.suggestedType(for: who) == .expense ? .other : YouTripParser.suggestedType(for: who)
        } else if outgoing {
            type = .expense
        } else {
            type = YouTripParser.type(for: name, incoming: true)
        }
        return ParsedTransaction(date: date, description: description, amountSGD: amount, localAmount: nil, localCurrency: nil,
                                 transactionType: type, account: .dbs, isOutflow: outgoing)
    }
}

/// PayLah history: a name and "SGD 16.00" per entry under "08 OCT"-style headers. The only sign of money coming in is
/// that its amount is printed in green, so the colour of the amount's pixels is read.
enum PayLahParser {
    private static let amountRow = Rx(#"^\s*SGD\s*(\d[\d,]*[.,]\d{2})\s*>?\s*$"#, ignoreCase: true)
    private static let dateHeader = Rx(#"^\s*\d{1,2}\s+[A-Za-z]{3}\s*$"#)
    private static let chrome: Set<String> = ["history", "paylah!", "paylah", "home", "rewards", "more", ">", "is."]

    static func parse(_ ocr: OCRResult, image: CGImage?) -> [ParsedTransaction] {
        var result: [ParsedTransaction] = []
        var date: Date?
        var names: [String] = []

        for line in ocr.lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if dateHeader.test(text), let parsed = Dates.parse(text) { date = parsed; names = []; continue }
            if let m = amountRow.first(in: text), let digits = m.group(1) {
                let amount = Double(digits.replacingOccurrences(of: ",", with: "")) ?? 0
                let name = names.joined(separator: " ")
                names = []
                guard !name.isEmpty, date != nil else { continue }
                let green = image.map { ColorProbe.isGreen($0, in: line.box) } ?? false
                result.append(entry(name: name, amount: amount, incoming: green, date: date))
                continue
            }
            let cleaned = text.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty || chrome.contains(cleaned.lowercased()) || Rx(#"^\d{1,2}[:.]\d{2}"#).test(cleaned) { continue }
            names.append(cleaned)
        }
        return result
    }

    private static func entry(name: String, amount: Double, incoming: Bool, date: Date?) -> ParsedTransaction {
        let lowered = name.lowercased()
        var type: TransactionType = .expense
        var description = name
        if incoming {
            if lowered.hasPrefix("top up") { type = .transferOwnAccount; description = "Top-up from DBS" }   // PayLah refilling itself from the bank
            else { type = YouTripParser.type(for: name, incoming: true) }
        }
        return ParsedTransaction(date: date, description: description, amountSGD: amount, localAmount: nil, localCurrency: nil,
                                 transactionType: type, account: .paylah, isOutflow: !incoming)
    }
}

/// Reads the colour of text: money in is green in PayLah.
enum ColorProbe {
    static func isGreen(_ image: CGImage, in box: CGRect) -> Bool {
        let bounds = box.insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounds.isEmpty, let crop = image.cropping(to: bounds) else { return false }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r = 0, g = 0, b = 0, count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (pr, pg, pb) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            guard (pr + pg + pb) / 3 < 200 else { continue }   // ink only, not the white card behind it
            r += pr; g += pg; b += pb; count += 1
        }
        guard count > 8 else { return false }
        let (mr, mg, mb) = (r / count, g / count, b / count)
        return mg > mr + 20 && mg > mb + 20
    }
}
