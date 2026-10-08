import Foundation
import SwiftData

/// One balance check: what the user typed in as their actual balance, versus what the tracked
/// transactions implied it should be. Mirrors `balance_reconciliations`.
@Model
final class BalanceReconciliation {
    /// Insertion order - "the latest check" means the last one entered, not the latest date.
    var createdAt: Date = Date()
    var reconciledOn: Date = Date()
    var actualSGD: Double = 0
    var impliedSGD: Double?
    var untrackedSGD: Double = 0
    /// createdAt of the newest transaction known at the time, so a transaction entered late (even
    /// back-dated) is counted as new movement against the next balance check.
    var knownThrough: Date?

    init(reconciledOn: Date, actualSGD: Double, impliedSGD: Double?, untrackedSGD: Double,
         knownThrough: Date?) {
        self.reconciledOn = reconciledOn
        self.actualSGD = actualSGD
        self.impliedSGD = impliedSGD
        self.untrackedSGD = untrackedSGD
        self.knownThrough = knownThrough
    }
}

/// A checkpoint each time the paid-for-others balance settles back to exactly $0 - lets "recent
/// activity" show what's happened since the last time everything was square, per the zero-balance
/// checkpoint idea, without needing to allocate debt to specific people. Snapshots exactly which
/// items/reimbursements it covered, since spending can be entered late and a back-dated item must
/// still show up as new.
@Model
final class BalanceCheckpoint {
    var recordedAt: Date = Date()
    /// Date of the latest activity this checkpoint covers (for display).
    var reachedAt: Date = Date()
    var paidTotal: Double = 0
    var receivedTotal: Double = 0
    var coveredItemIDs: [String] = []
    var coveredReimbursementIDs: [String] = []

    init(reachedAt: Date, paidTotal: Double, receivedTotal: Double,
         coveredItemIDs: [String], coveredReimbursementIDs: [String]) {
        self.reachedAt = reachedAt
        self.paidTotal = paidTotal
        self.receivedTotal = receivedTotal
        self.coveredItemIDs = coveredItemIDs
        self.coveredReimbursementIDs = coveredReimbursementIDs
    }
}
