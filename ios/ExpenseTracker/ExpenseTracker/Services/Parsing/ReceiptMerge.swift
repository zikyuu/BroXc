import Foundation

/// Combines several readings of the same receipt into one. The printed total is the referee: a change is only taken
/// when it brings the lines closer to adding up to it, so a reading can fill in a line the others missed or correct a
/// price they garbled, but can't just overwrite what was already right.
enum ReceiptMerge {
    struct Entry: Identifiable {
        let id = UUID()
        var item: ParsedLineItem
        /// Position in the list this was built from, or nil for a line brought in from another reading.
        var base: Int?
    }

    /// Two names this similar (0...100) are the same product.
    static let sameName = 80.0
    static let tolerance = 0.011

    static func closes(_ items: [ParsedLineItem], total: Double?) -> Bool {
        guard let total else { return false }
        return abs(total - items.reduce(0) { $0 + $1.price }) <= tolerance
    }

    private static func key(_ name: String) -> String { name.lowercased().filter(\.isLetter) }

    /// What one reading could change: replace the price of a line it shares with the receipt, or add a line the receipt lacks.
    private enum Change {
        case swap(line: Int, entry: UUID, to: ParsedLineItem)
        case add(line: Int)
    }

    static func combine(base: [ParsedLineItem], total: Double, others: [[ParsedLineItem]]) -> [Entry] {
        var entries = base.enumerated().map { Entry(item: $1, base: $0) }
        func gap() -> Double { round2(total - entries.reduce(0) { $0 + $1.item.price }) }

        for other in others {
            if abs(gap()) <= tolerance { return entries }
            // say which existing line each line of this reading is (if any)
            var matchID: [UUID?] = []
            var taken = Set<UUID>()
            for line in other {
                var best: (id: UUID, similarity: Double, priceDiff: Double)?
                for entry in entries where !taken.contains(entry.id) && entry.item.isDeposit == line.isDeposit {
                    let similarity = Fuzzy.partialRatio(key(entry.item.name), key(line.name))
                    guard similarity >= sameName else { continue }
                    let diff = abs(entry.item.price - line.price)
                    if best == nil || similarity > best!.similarity || (similarity == best!.similarity && diff < best!.priceDiff) { best = (entry.id, similarity, diff) }
                }
                if let best { taken.insert(best.id) }
                matchID.append(best?.id)
            }
            // every change this reading offers, and by how much each would move the gap
            var changes: [(change: Change, delta: Double)] = []
            for (n, line) in other.enumerated() {
                if let id = matchID[n], let entry = entries.first(where: { $0.id == id }) {
                    if abs(entry.item.price - line.price) > 0.001 { changes.append((.swap(line: n, entry: id, to: line), entry.item.price - line.price)) }
                } else {
                    changes.append((.add(line: n), -line.price))
                }
            }
            changes = Array(changes.prefix(14))
            // The total is a checksum, so look for the set of changes that makes the lines add up exactly - not each
            // change on its own merit, which can be fooled (a wrong extra line plus a right price swap can cancel out
            // the other way and overshoot).
            let start = gap()
            var chosen: (mask: Int, final: Double)?
            for mask in 1..<(1 << changes.count) {
                let final = round2(start + changes.enumerated().reduce(0) { $0 + (mask & (1 << $1.offset) != 0 ? $1.element.delta : 0) })
                let count = mask.nonzeroBitCount
                if abs(final) <= tolerance {
                    if chosen == nil || abs(chosen!.final) > tolerance || count < chosen!.mask.nonzeroBitCount { chosen = (mask, final) }
                } else if final >= -tolerance, abs(final) < abs(start) - 0.0001, chosen == nil || (abs(chosen!.final) > tolerance && (abs(final) < abs(chosen!.final) - 0.0001
                          || (abs(final) == abs(chosen!.final) && count < chosen!.mask.nonzeroBitCount))) {
                    chosen = (mask, final)
                }
            }
            guard let chosen else { continue }
            var previous: UUID?
            for (n, line) in other.enumerated() {
                let picked = changes.enumerated().first { (i, c) in
                    guard chosen.mask & (1 << i) != 0 else { return false }
                    switch c.change { case .swap(let l, _, _): return l == n; case .add(let l): return l == n }
                }
                if let id = matchID[n] { previous = id }
                guard let picked else { continue }
                switch picked.element.change {
                case .swap(_, let id, let to):
                    if let index = entries.firstIndex(where: { $0.id == id }) {
                        entries[index].item.price = to.price; entries[index].item.originalPrice = to.originalPrice; entries[index].item.discount = to.discount
                    }
                case .add:
                    let new = Entry(item: line, base: nil)
                    let after = previous.flatMap { id in entries.firstIndex { $0.id == id } }.map { $0 + 1 }
                    let before = other[(n + 1)...].indices.compactMap { matchID[$0] }.first.flatMap { id in entries.firstIndex { $0.id == id } }
                    entries.insert(new, at: after ?? before ?? entries.count)
                    previous = new.id
                }
            }
        }
        return entries
    }
}
