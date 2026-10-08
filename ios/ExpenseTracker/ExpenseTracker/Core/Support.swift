import Foundation

// MARK: - Dates

/// Date parsing and month arithmetic. Everything is "start of day, local time": a receipt has a day,
/// not a moment. Mirrors `shared/dates.py` - ISO is read as-is, anything else day-first, since that's
/// how the European receipts this app sees write ambiguous dates.
enum Dates {
    static var calendar: Calendar { Calendar.current }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : String(text[Range(range, in: text)!])
        }
    }

    static func parse(_ text: String?, today: Date = Date()) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let m = firstMatch(#"(\d{4})-(\d{2})-(\d{2})"#, in: text),
           let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) { return day(y, mo, d) }
        if let m = firstMatch(#"\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*(?:\s+(\d{2,4}))?\b"#, in: text),
           let d = Int(m[1]), let mo = months[m[2].lowercased()] {
            if var y = Int(m[3]) {
                if y < 100 { y += 2000 }
                return day(y, mo, d)
            }
            // no year printed (YouTrip's own date headers sometimes omit it): the current year, unless
            // that would put it in the future - then it's last year's (a December screenshot read in January)
            let thisYear = calendar.component(.year, from: today)
            if let candidate = day(thisYear, mo, d) {
                return candidate > today.addingTimeInterval(86_400 * 31) ? day(thisYear - 1, mo, d) : candidate
            }
        }
        if let m = firstMatch(#"\b(\d{1,2})[./](\d{1,2})[./](\d{2,4})\b"#, in: text),
           let d = Int(m[1]), let mo = Int(m[2]), var y = Int(m[3]) {
            if y < 100 { y += 2000 }
            return day(y, mo, d)
        }
        return nil
    }

    static func daysApart(_ a: Date, _ b: Date) -> Int {
        abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0)
    }
}

/// A calendar month, comparable and hashable, used wherever spending is grouped by month.
struct MonthKey: Hashable, Comparable, Identifiable {
    let year: Int
    let month: Int
    var id: String { String(format: "%04d-%02d", year, month) }

    init(year: Int, month: Int) { self.year = year; self.month = month }
    init(_ date: Date) {
        year = Dates.calendar.component(.year, from: date)
        month = Dates.calendar.component(.month, from: date)
    }
    static var current: MonthKey { MonthKey(Date()) }

    static func < (a: MonthKey, b: MonthKey) -> Bool { (a.year, a.month) < (b.year, b.month) }

    func shifted(by delta: Int) -> MonthKey {
        let index = year * 12 + (month - 1) + delta
        return MonthKey(year: index / 12, month: index % 12 + 1)
    }
    var firstDay: Date { Dates.day(year, month, 1)! }
    var daysInMonth: Int { Dates.calendar.range(of: .day, in: .month, for: firstDay)!.count }
    var lastDay: Date { Dates.day(year, month, daysInMonth)! }
    var label: String {
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f.string(from: firstDay)
    }
    var shortLabel: String {
        let f = DateFormatter(); f.dateFormat = "LLL"; return f.string(from: firstDay)
    }
}

extension Date {
    var dayOfMonth: Int { Dates.calendar.component(.day, from: self) }
    var startOfDay: Date { Dates.calendar.startOfDay(for: self) }
}

// MARK: - Money

enum Money {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
    private static let wholeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f
    }()

    /// $1,234.50 - for individual amounts. "~" marks an estimate, "+" an incoming sign.
    static func string(_ value: Double?, estimated: Bool = false, sign: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        let text = formatter.string(from: NSNumber(value: abs(value))) ?? "0.00"
        let prefix = value < -0.004 ? "−" : (sign && value > 0.004 ? "+" : "")
        return "\(prefix)\(estimated ? "~" : "")$\(text)"
    }

    /// $1,234 - for big round summaries.
    static func whole(_ value: Double) -> String {
        let text = wholeFormatter.string(from: NSNumber(value: abs(value.rounded()))) ?? "0"
        return "\(value.rounded() < 0 ? "−" : "")$\(text)"
    }
}

func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

// MARK: - Fuzzy matching (a stand-in for rapidfuzz.fuzz.partial_ratio)

enum Fuzzy {
    /// Longest common subsequence length.
    private static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    /// rapidfuzz's `ratio`: 100 * 2 * LCS / (len a + len b).
    static func ratio(_ a: [Character], _ b: [Character]) -> Double {
        let total = a.count + b.count
        return total == 0 ? 100 : 100 * Double(2 * lcs(a, b)) / Double(total)
    }

    /// Best `ratio` between the shorter string and any same-length window of the longer one (plus the
    /// shorter partial windows at both ends). 0-100. Case-insensitive.
    static func partialRatio(_ first: String, _ second: String) -> Double {
        var short = Array(first.lowercased()), long = Array(second.lowercased())
        if short.count > long.count { swap(&short, &long) }
        if short.isEmpty { return 0 }
        var best = 0.0
        for start in 0...(long.count - short.count) {
            best = max(best, ratio(short, Array(long[start..<(start + short.count)])))
            if best >= 100 { return 100 }
        }
        if short.count > 1 {
            for size in 1..<short.count {
                best = max(best, ratio(short, Array(long.prefix(size))))
                best = max(best, ratio(short, Array(long.suffix(size))))
            }
        }
        return best
    }
}

// MARK: - Hungarian algorithm (optimal assignment), a stand-in for scipy's linear_sum_assignment

enum Hungarian {
    /// Minimum-total-cost assignment on a possibly rectangular matrix. Returns (row, column) pairs -
    /// one per row when there are at least as many columns, otherwise one per column.
    static func solve(_ cost: [[Double]]) -> [(row: Int, column: Int)] {
        guard let width = cost.first?.count, width > 0 else { return [] }
        let height = cost.count
        if height > width {
            let transposed = (0..<width).map { c in (0..<height).map { r in cost[r][c] } }
            return solve(transposed).map { (row: $0.column, column: $0.row) }
        }
        let n = height, m = width
        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: m + 1)
        var p = [Int](repeating: 0, count: m + 1)
        var way = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...m where !used[j] {
                    let current = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if current < minv[j] { minv[j] = current; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...m {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        return (1...m).compactMap { j in p[j] == 0 ? nil : (row: p[j] - 1, column: j - 1) }
    }
}
