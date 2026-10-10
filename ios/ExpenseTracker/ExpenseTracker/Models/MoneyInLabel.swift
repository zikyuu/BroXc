import Foundation
import SwiftData

/// A category the user made for money coming in that is neither a reimbursement nor a top-up - "Allowance",
/// "Scholarship", "Selling my old bike". Stored as an income transaction carrying this label.
@Model
final class MoneyInLabel {
    var name: String = ""
    var sortOrder: Int = 0

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }
}
