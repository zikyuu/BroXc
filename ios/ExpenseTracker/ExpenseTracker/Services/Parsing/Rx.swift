import Foundation

/// A small wrapper over NSRegularExpression with Python-`re`-like helpers, so the parsers port line for line.
struct Rx {
    struct Match {
        let range: Range<String.Index>
        let groups: [String?]
        var text: String { groups[0] ?? "" }
        func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    let regex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private func build(_ m: NSTextCheckingResult, _ text: String) -> Match {
        let groups: [String?] = (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : String(text[Range(r, in: text)!])
        }
        return Match(range: Range(m.range, in: text)!, groups: groups)
    }

    func first(in text: String) -> Match? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { build($0, text) }
    }

    func all(in text: String) -> [Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { build($0, text) }
    }

    func test(_ text: String) -> Bool { first(in: text) != nil }

    func replacingAll(in text: String, with template: String = "") -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    func replacingFirst(in text: String, with template: String = "") -> String {
        guard let m = first(in: text) else { return text }
        return text.replacingCharacters(in: m.range, with: template)
    }

    /// Replaces every match with whatever `transform` returns for it.
    func replacingAll(in text: String, _ transform: (Match) -> String) -> String {
        var result = text
        for m in all(in: text).reversed() { result.replaceSubrange(m.range, with: transform(m)) }
        return result
    }
}

extension String {
    /// Python's `str.strip(chars)`.
    func stripped(of characters: String) -> String {
        let set = CharacterSet(charactersIn: characters)
        var s = Substring(self)
        while let f = s.unicodeScalars.first, set.contains(f) { s = s.dropFirst() }
        while let l = s.unicodeScalars.last, set.contains(l) { s = s.dropLast() }
        return String(s)
    }

    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
