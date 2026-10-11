import XCTest
import SwiftData
@testable import ExpenseTracker

/// The DBS and PayLah screens as they really look (personal screenshots, gitignored: skipped where they're absent).
final class BankScreenshotTests: XCTestCase {
    private func load(_ name: String) throws -> CGImage {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let file = dir.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "\(name) isn't in the repo folder")
        return try XCTUnwrap(UIImage(contentsOfFile: file.path)?.cgImage)
    }

    func testDBSHistoryScreenshot() async throws {
        let read = try await ReceiptReader.readTransactions(try load("dbs_history.jpg"))
        XCTAssertEqual(read.kind, .dbs)
        XCTAssertNotNil(read.hint.number?.range(of: #"^\d{3}-\d{4,6}-\d{1,3}$"#, options: .regularExpression), "the account number in the header is found")
        XCTAssertTrue(read.hint.name?.hasSuffix("Account") ?? false, "the drop-down arrow isn't part of the name: \(read.hint.name ?? "-")")
        let rows = read.transactions
        for t in rows { print("DBS \(t.date.map { "\($0)" } ?? "-") | \(t.description ?? "-") | \(t.amountSGD ?? 0) | \(t.transactionType) out=\(t.isOutflow)") }
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map { $0.amountSGD ?? 0 }, [200, 16, 850, 139.63, 2.28])
        XCTAssertEqual(rows.map(\.isOutflow), [true, true, false, true, true])
        XCTAssertEqual(rows.map(\.transactionType), [.transferOwnAccount, .transferOwnAccount, .other, .expense, .transferOwnAccount])
        XCTAssertTrue(rows.allSatisfy { $0.account == .dbs })
        XCTAssertEqual(rows[0].description, "YouTrip top-up")
        XCTAssertTrue(rows[3].description?.hasPrefix("PayNow to ") ?? false, rows[3].description ?? "")
        XCTAssertEqual(rows[0].date, Dates.day(2026, 10, 9))
        XCTAssertEqual(rows[3].date, Dates.day(2026, 10, 6))
    }

    /// The savings ("Savings") account: dates without a weekday, "·" separators, a transfer by account number, interest.
    func testSavingsAccountScreenshot() async throws {
        let read = try await ReceiptReader.readTransactions(try load("dbs_exchange.jpg"))
        XCTAssertEqual(read.kind, .dbs)
        XCTAssertNotNil(read.hint.number?.range(of: #"^\d{3}-\d{4,6}-\d{1,3}$"#, options: .regularExpression))
        XCTAssertFalse(read.hint.name?.isEmpty ?? true)
        let rows = read.transactions
        for t in rows { print("EXCHANGE \(t.description ?? "-") | \(t.amountSGD ?? 0) | \(t.transactionType) out=\(t.isOutflow)") }
        XCTAssertEqual(rows.map { $0.amountSGD ?? 0 }, [0.30, 2000, 138.87])
        XCTAssertEqual(rows.map(\.isOutflow), [false, true, true])
        XCTAssertEqual(rows.map(\.transactionType), [.income, .transferOwnAccount, .expense])
        XCTAssertNotNil(rows[1].description?.range(of: #"^Transfer to \d{3}-\d{4,6}-\d{1,3}"#, options: .regularExpression), "the wrapped account number is rejoined: \(rows[1].description ?? "-")")
        XCTAssertTrue(rows[2].description?.hasPrefix("PayNow to ") ?? false, rows[2].description ?? "")
        XCTAssertEqual(rows.map(\.date), [Dates.day(2026, 9, 30), Dates.day(2026, 9, 25), Dates.day(2026, 9, 17)])
    }

    func testPayLahHistoryScreenshot() async throws {
        let read = try await ReceiptReader.readTransactions(try load("paylah_history.jpg"))
        XCTAssertEqual(read.kind, .paylah)
        let rows = read.transactions
        for t in rows { print("PAYLAH \(t.date.map { "\($0)" } ?? "-") | \(t.description ?? "-") | \(t.amountSGD ?? 0) | \(t.transactionType) out=\(t.isOutflow)") }
        XCTAssertEqual(rows.map { $0.description ?? "" }.filter { $0 == "Top-up from DBS" }.count, 2)
        XCTAssertTrue(rows.allSatisfy { !($0.description ?? "").isEmpty })
        XCTAssertEqual(rows.map { $0.amountSGD ?? 0 }, [16, 16, 2.28, 28.45, 30.13, 3])
        XCTAssertEqual(rows.map(\.isOutflow), [true, false, false, true, true, false], "green amounts are money in")
        XCTAssertEqual(rows.map(\.transactionType), [.expense, .transferOwnAccount, .transferOwnAccount, .expense, .expense, .income])
        XCTAssertEqual(rows[0].date, Dates.day(2026, 10, 8))
    }

    func testWhichAppAScreenshotIsFrom() {
        XCTAssertEqual(ScreenshotKind.detect(["Friday, 9 Oct 2026", "YouTrip", "SGD - 200.00"]), .dbs)
        XCTAssertEqual(ScreenshotKind.detect(["History", "PayLah!", "08 OCT", "feed me", "SGD 16.00"]), .paylah)
        XCTAssertEqual(ScreenshotKind.detect(["09 Oct 2026", "ICA kr395.39 SEK", "50.85 SGD", "SmartExchange"]), .youtrip)
    }
}

@MainActor
final class TransferPairingTests: LedgerTestCase {
    private func transfer(_ date: String, _ description: String, _ amount: Double, account: Account, out: Bool) -> YouTripTransaction {
        let t = addTxn(date, description, amount, type: .transferOwnAccount)
        t.account = account; t.isOutflow = out
        return t
    }

    /// DBS shows the YouTrip top-up two days after YouTrip does: still one move, and neither half is spending.
    func testDelayedBankTransferStillPairs() {
        let youtrip = transfer("2026-10-07", "Top Up", 200, account: .youtrip, out: false)
        let dbs = transfer("2026-10-09", "YouTrip top-up", 200, account: .dbs, out: true)
        let pairing = TransferPairing.pair(ledger().transactions, today: day("2026-10-11"))
        XCTAssertEqual(pairing.partner[youtrip.uid], dbs.uid)
        XCTAssertEqual(pairing.partner[dbs.uid], youtrip.uid)
        XCTAssertTrue(pairing.waiting.isEmpty && pairing.missing.isEmpty)
        XCTAssertEqual(ledger().categoryTree().totalSGD, 0, "a transfer isn't spending")
    }

    func testUnpairedHalfIsWaitingThenMissing() {
        let top = transfer("2026-10-09", "Top Up", 300, account: .youtrip, out: false)
        XCTAssertEqual(TransferPairing.pair(ledger().transactions, today: day("2026-10-11")).waiting.map(\.uid), [top.uid], "DBS may not have posted it yet")
        XCTAssertEqual(TransferPairing.pair(ledger().transactions, today: day("2026-10-20")).missing.map(\.uid), [top.uid], "ten days on, something is missing")
    }

    func testPayLahTopUpPairsWithTheRightBankLegOnly() {
        let a = transfer("2026-10-08", "Top-up from DBS", 16, account: .paylah, out: false)
        let toYouTrip = transfer("2026-10-09", "YouTrip top-up", 16, account: .dbs, out: true)   // same amount, but headed to YouTrip
        XCTAssertNil(TransferPairing.pair(ledger().transactions, today: day("2026-10-11")).partner[a.uid])
        let toPayLah = transfer("2026-10-09", "Top-up to PayLah", 16, account: .dbs, out: true)
        let pairing = TransferPairing.pair(ledger().transactions, today: day("2026-10-11"))
        XCTAssertEqual(pairing.partner[a.uid], toPayLah.uid)
        XCTAssertNil(pairing.partner[toYouTrip.uid])
    }

    func testBalanceMovesWithTheDirectionOfTheMoney() {
        let first = ledger()
        Actions.reconcile(actual: 1000, on: day("2026-10-01"), account: .dbs, ledger: first, in: context)
        transfer("2026-10-05", "YouTrip top-up", 200, account: .dbs, out: true)
        let income = addTxn("2026-10-06", "GST voucher", 850, type: .other)
        income.account = .dbs
        XCTAssertEqual(ledger().currentBalance(for: .dbs)?.implied ?? 0, 1650, accuracy: 0.001, "1000 - 200 out + 850 in")
    }

    func testSameAmountOnDifferentAccountsIsNotADuplicate() throws {
        let a = ParsedTransaction(date: day("2026-10-08"), description: "feed me", amountSGD: 16, transactionType: .expense, account: .paylah, isOutflow: true)
        let b = ParsedTransaction(date: day("2026-10-08"), description: "feed me", amountSGD: 16, transactionType: .expense, account: .dbs, isOutflow: true)
        XCTAssertEqual(Actions.saveNew([a], in: context).added, 1)
        XCTAssertEqual(Actions.saveNew([b], in: context).added, 1, "another account's row is its own")
        XCTAssertEqual(Actions.saveNew([a], in: context).skipped, 1, "the same account's row twice is a repeat")
    }

    /// Two DBS accounts (spending and a fixed deposit) are kept apart by the number DBS prints in the header.
    func testAScreenshotIsFiledUnderTheAccountItsNumberNames() throws {
        AccountSeeder.ensureDefaults(in: context)
        // first time a number is seen: the plain "DBS" account takes it, so existing records stay put
        let spending = Actions.resolveAccount(kind: .dbs, hint: ("Everyday Account", "111-11111-1"), in: context)
        XCTAssertEqual(spending, .dbs)
        XCTAssertEqual(ledger().info(.dbs).name, "Everyday Account")
        // a different number is a different account
        let deposit = Actions.resolveAccount(kind: .dbs, hint: ("Fixed Deposit", "333-33333-3"), in: context)
        XCTAssertNotEqual(deposit, .dbs)
        XCTAssertEqual(ledger().info(deposit).name, "Fixed Deposit")
        // seen again: recognised, not duplicated
        XCTAssertEqual(Actions.resolveAccount(kind: .dbs, hint: (nil, "333-33333-3"), in: context), deposit)
        XCTAssertEqual(Actions.resolveAccount(kind: .dbs, hint: (nil, "111-11111-1"), in: context), .dbs)
        XCTAssertEqual(ledger().accounts.count, 4)
        // YouTrip and PayLah screenshots never need a number
        XCTAssertEqual(Actions.resolveAccount(kind: .paylah, hint: (nil, nil), in: context), .paylah)
    }

    /// Topping up the spending account from the fixed deposit: out of one DBS account, into another. Not spending.
    func testMoveBetweenTwoDBSAccountsPairs() throws {
        AccountSeeder.ensureDefaults(in: context)
        let deposit = Account(rawValue: try Actions.addAccount(name: "Fixed Deposit", kind: .savings, number: "333-33333-3", in: context).key)
        let first = ledger()
        Actions.reconcile(actual: 10000, on: day("2026-10-01"), account: deposit, ledger: first, in: context)
        let out = addTxn("2026-10-03", "Transfer to Everyday", 500, type: .transferOwnAccount)
        out.account = deposit; out.isOutflow = true
        let into = addTxn("2026-10-03", "Transfer from Fixed Deposit", 500, type: .transferOwnAccount)
        into.account = .dbs
        let l = ledger()
        XCTAssertEqual(TransferPairing.pair(l.transactions, accounts: l.accounts, today: day("2026-10-05")).partner[out.uid], into.uid)
        XCTAssertEqual(l.currentBalance(for: deposit)?.implied ?? 0, 9500, accuracy: 0.001)
        XCTAssertEqual(l.categoryTree().totalSGD, 0, "a move between your own accounts isn't spending")
    }

    func testAnAccountWithRecordsCannotBeDeleted() throws {
        AccountSeeder.ensureDefaults(in: context)
        let made = try Actions.addAccount(name: "Savings", kind: .savings, number: nil, in: context)
        XCTAssertThrowsError(try Actions.addAccount(name: "savings", kind: .bank, number: nil, in: context), "names are unique")
        let t = addTxn("2026-10-03", "x", 5, type: .income)
        t.sourceRaw = made.key
        XCTAssertThrowsError(try Actions.deleteAccount(made, in: context))
        context.delete(t)
        XCTAssertNoThrow(try Actions.deleteAccount(made, in: context))
    }

    /// "TRF ... 111-11111-1" is a move between your own accounts only because 111-11111-1 is one of them, and the other side
    /// (a bare "+2,000" with no description) is recognised as its other half.
    func testTransferByAccountNumberPairsAndFindsTheOtherSide() throws {
        AccountSeeder.ensureDefaults(in: context)
        let spending = try XCTUnwrap(try context.fetch(FetchDescriptor<BankAccount>()).first { $0.key == "dbs" })
        spending.number = "111-11111-1"
        let savings = try Actions.addAccount(name: "Savings", kind: .savings, number: "222-22222-2", in: context)
        let row = ParsedTransaction(date: day("2026-09-25"), description: "Transfer to 111-11111-1 (IB travelling)", amountSGD: 2000,
                                    transactionType: .transferOwnAccount, account: Account(rawValue: savings.key), isOutflow: true)
        let stranger = ParsedTransaction(date: day("2026-09-25"), description: "Transfer to 999-12345-6", amountSGD: 50,
                                         transactionType: .transferOwnAccount, account: Account(rawValue: savings.key), isOutflow: true)
        let settled = Actions.settleTransfers([row, stranger], in: context)
        XCTAssertEqual(settled.map(\.transactionType), [.transferOwnAccount, .expense], "a number that isn't yours is just a payment")
        Actions.saveNew(settled, in: context)
        let incoming = ParsedTransaction(date: day("2026-09-26"), description: "FUND TRANSFER", amountSGD: 2000, transactionType: .other, account: .dbs, isOutflow: false)
        Actions.saveNew([incoming], in: context)
        Actions.relinkTransfers(in: context)
        let l = ledger()
        XCTAssertTrue(l.transactions.filter { $0.transactionType == .transferOwnAccount }.count == 2, "both halves are now a move")
        let pairing = TransferPairing.pair(l.transactions, accounts: l.accounts, today: day("2026-09-28"))
        XCTAssertEqual(pairing.partner.count, 2)
        XCTAssertEqual(l.categoryTree().totalSGD, 50, "only the 50 sent to a stranger is spending")
    }

    func testAnAccountNumberAddedLaterTurnsEarlierTransfersIntoMoves() throws {
        AccountSeeder.ensureDefaults(in: context)
        let savings = try Actions.addAccount(name: "Savings", kind: .savings, number: "222-22222-2", in: context)
        let row = ParsedTransaction(date: day("2026-09-25"), description: "Transfer to 111-11111-1 (IB travelling)", amountSGD: 2000,
                                    transactionType: .transferOwnAccount, account: Account(rawValue: savings.key), isOutflow: true)
        Actions.saveNew(Actions.settleTransfers([row], in: context), in: context)
        XCTAssertEqual(ledger().transactions.first?.transactionType, .expense, "111-11111-1 isn't a known account yet")
        let spending = try XCTUnwrap(try context.fetch(FetchDescriptor<BankAccount>()).first { $0.key == "dbs" })
        spending.number = "111-11111-1"
        Actions.relinkTransfers(in: context)
        XCTAssertEqual(ledger().transactions.first?.transactionType, .transferOwnAccount)
    }

    /// Put the new account between DBS and PayLah by dragging it there.
    func testAccountsCanBeReordered() throws {
        AccountSeeder.ensureDefaults(in: context)
        let exchange = try Actions.addAccount(name: "Savings", kind: .savings, number: nil, in: context)
        XCTAssertEqual(ledger().accounts.map(\.name), ["DBS", "PayLah", "YouTrip", "Savings"], "new accounts start on the right")
        Actions.moveAccount(exchange.key, to: "paylah", in: context)
        XCTAssertEqual(ledger().accounts.map(\.name), ["DBS", "Savings", "PayLah", "YouTrip"])
        Actions.moveAccount("dbs", to: "youtrip", in: context)
        XCTAssertEqual(ledger().accounts.map(\.name), ["Savings", "PayLah", "YouTrip", "DBS"], "dragged down: lands after")
        let later = try Actions.addAccount(name: "Cash", kind: .bank, number: nil, in: context)
        XCTAssertEqual(ledger().accounts.last?.name, later.name)
    }
}
