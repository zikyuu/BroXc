import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
class LedgerTestCase: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema([ExpenseTracker.Category.self, Trip.self, Receipt.self, LineItem.self, LineItemShare.self,
                             YouTripTransaction.self, BalanceReconciliation.self, BalanceCheckpoint.self, ItemRule.self, MoneyInLabel.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = container.mainContext
        CategorySeeder.seedIfNeeded(in: context)
    }

    func ledger() -> Ledger {
        func all<T: PersistentModel>(_ type: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
        return Ledger(receipts: all(Receipt.self), transactions: all(YouTripTransaction.self), categories: all(ExpenseTracker.Category.self),
                      trips: all(Trip.self), reconciliations: all(BalanceReconciliation.self),
                      checkpoints: all(BalanceCheckpoint.self), rules: all(ItemRule.self))
    }

    func day(_ text: String) -> Date { Dates.parse(text)! }

    @discardableResult
    func addReceipt(_ merchant: String, _ date: String, currency: String = "SGD", itemised: Bool = true,
                    trip: Trip? = nil, _ items: [(String, Double, [String])]) -> Receipt {
        let receipt = Receipt(merchant: merchant, date: day(date), currency: currency, total: items.reduce(0) { $0 + $1.1 },
                              rawText: itemised ? "x" : nil, trip: trip ?? Actions.activeTrip(context))
        context.insert(receipt)
        for (i, entry) in items.enumerated() {
            let item = LineItem(name: entry.0, price: entry.1, tags: entry.2)
            item.position = i
            item.receipt = receipt
            context.insert(item)
        }
        try? context.save()
        return receipt
    }

    @discardableResult
    func addTxn(_ date: String, _ description: String, _ sgd: Double, local: Double? = nil, currency: String? = nil,
                type: TransactionType = .expense) -> YouTripTransaction {
        let t = YouTripTransaction(date: day(date), description: description, amountSGD: sgd, localAmount: local,
                                   localCurrency: currency, transactionType: type,
                                   trip: type == .expense ? Actions.activeTrip(context) : nil)
        context.insert(t)
        try? context.save()
        return t
    }

    func category(_ name: String) -> ExpenseTracker.Category { ledger().category(named: name)! }
}
