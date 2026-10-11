import Foundation

/// Matches the two halves of a move between your own accounts: DBS paying out $200 to YouTrip, and YouTrip showing
/// +$200. Neither half is spending or income. The halves don't show up together - DBS can take a few days to post
/// - so an unpaired half is first "waiting", and only "missing" once enough time has passed.
enum TransferPairing {
    /// A transfer may appear in the receiving account this many days before or after the sending one.
    static let windowDays = 5
    /// An unpaired transfer younger than this is probably just not posted yet.
    static let waitingDays = 4

    struct Result {
        /// uid -> the uid of the other half
        var partner: [String: String] = [:]
        var waiting: [YouTripTransaction] = []
        var missing: [YouTripTransaction] = []
    }

    /// Which account the money was headed for, when the sender's description names it ("Top-up to PayLah", "YouTrip top-up").
    private static func destination(of t: YouTripTransaction, among accounts: [AccountInfo]) -> Account? {
        let description = t.transactionDescription ?? ""
        if let byNumber = accounts.first(where: { $0.account != t.account && $0.number.map { description.contains($0) } == true }) { return byNumber.account }
        let text = description.lowercased().filter { $0.isLetter }
        return accounts.filter { $0.account != t.account && !$0.name.isEmpty && text.contains($0.name.lowercased().filter { $0.isLetter }) }
            .max { $0.name.count < $1.name.count }?.account
    }

    static func pair(_ transactions: [YouTripTransaction], accounts: [AccountInfo] = AccountInfo.defaults, today: Date = Date()) -> Result {
        let transfers = transactions.filter { $0.transactionType == .transferOwnAccount }
        let outs = transfers.filter(\.isOutflow), ins = transfers.filter { !$0.isOutflow }
        var candidates: [(out: YouTripTransaction, in: YouTripTransaction, days: Int)] = []
        for o in outs {
            for i in ins where i.account != o.account {
                guard abs(abs(o.amountSGD ?? -1) - abs(i.amountSGD ?? -2)) < 0.011 else { continue }
                if let wanted = destination(of: o, among: accounts), wanted != i.account { continue }
                if let source = destination(of: i, among: accounts), source != o.account { continue }
                let days = (o.date != nil && i.date != nil) ? Dates.daysApart(o.date!, i.date!) : windowDays
                guard days <= windowDays else { continue }
                candidates.append((o, i, days))
            }
        }
        var result = Result()
        var used = Set<String>()
        for c in candidates.sorted(by: { $0.days < $1.days }) where !used.contains(c.out.uid) && !used.contains(c.in.uid) {
            used.insert(c.out.uid); used.insert(c.in.uid)
            result.partner[c.out.uid] = c.in.uid
            result.partner[c.in.uid] = c.out.uid
        }
        for t in transfers where !used.contains(t.uid) {
            let age = t.date.map { Dates.daysApart($0, today) } ?? Int.max
            if age <= waitingDays { result.waiting.append(t) } else { result.missing.append(t) }
        }
        return result
    }
}
