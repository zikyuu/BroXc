import Foundation
import SwiftData
import SwiftUI

/// Which account a transaction or balance check belongs to. A small value that's stored as its `rawValue` key; the
/// accounts the user actually has (their names, kinds and numbers) are `BankAccount`s, so there can be two DBS accounts,
/// a fixed deposit, and so on.
struct Account: Hashable, Identifiable, Codable {
    var rawValue: String
    var id: String { rawValue }
    init(rawValue: String) { self.rawValue = rawValue }

    /// The three every install starts with. YouTrip is also what everything imported before there were several accounts is.
    static let dbs = Account(rawValue: "dbs")
    static let paylah = Account(rawValue: "paylah")
    static let youtrip = Account(rawValue: "youtrip")
}

enum AccountKind: String, CaseIterable, Identifiable {
    case bank, savings, wallet, card
    var id: String { rawValue }
    var label: String {
        switch self { case .bank: "Bank account"; case .savings: "Savings / fixed deposit"; case .wallet: "Wallet (PayLah)"; case .card: "Travel card" }
    }
    var icon: String {
        switch self { case .bank, .savings: "asset:acct-bank"; case .wallet: "asset:acct-paylah"; case .card: "asset:acct-youtrip" }
    }
}

/// One of the user's accounts. `number` is how a screenshot is recognised (DBS prints it under the account name).
@Model
final class BankAccount {
    var key: String = UUID().uuidString
    var name: String = ""
    var kindRaw: String = AccountKind.bank.rawValue
    var number: String?
    var sortOrder: Int = 0

    init(key: String = UUID().uuidString, name: String, kind: AccountKind, number: String? = nil, sortOrder: Int = 0) {
        self.key = key
        self.name = name
        self.kindRaw = kind.rawValue
        self.number = number
        self.sortOrder = sortOrder
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .bank }
        set { kindRaw = newValue.rawValue }
    }
}

/// What screens need to show an account, whether it's stored or one of the built-in defaults.
struct AccountInfo: Identifiable, Hashable {
    let account: Account
    let name: String
    let kind: AccountKind
    let number: String?
    var id: String { account.rawValue }
    var icon: String { kind.icon }

    init(_ model: BankAccount) { account = Account(rawValue: model.key); name = model.name; kind = model.kind; number = model.number }
    init(account: Account, name: String, kind: AccountKind, number: String? = nil) {
        self.account = account; self.name = name; self.kind = kind; self.number = number
    }

    static let defaults = [
        AccountInfo(account: .dbs, name: "DBS", kind: .bank),
        AccountInfo(account: .paylah, name: "PayLah", kind: .wallet),
        AccountInfo(account: .youtrip, name: "YouTrip", kind: .card),
    ]
}

/// Long-press an account (on Home or in the Accounts list) and drag it onto another to reorder.
struct AccountReorder: ViewModifier {
    let key: String
    @Environment(\.modelContext) private var context
    @State private var targeted = false
    private static let prefix = "account:"

    func body(content: Content) -> some View {
        content
            .draggable(Self.prefix + key)
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first, dragged.hasPrefix(Self.prefix) else { return false }
                Actions.moveAccount(String(dragged.dropFirst(Self.prefix.count)), to: key, in: context)
                return true
            } isTargeted: { targeted = $0 }
            .overlay(alignment: .leading) { if targeted { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 2) } }
    }
}

extension View {
    func reorderableAccount(_ key: String) -> some View { modifier(AccountReorder(key: key)) }
}

enum AccountSeeder {
    /// A first launch gets DBS, PayLah and YouTrip; an existing set is never touched.
    static func ensureDefaults(in context: ModelContext) {
        guard ((try? context.fetchCount(FetchDescriptor<BankAccount>())) ?? 0) == 0 else { return }
        for (order, info) in AccountInfo.defaults.enumerated() {
            context.insert(BankAccount(key: info.account.rawValue, name: info.name, kind: info.kind, sortOrder: order))
        }
        try? context.save()
    }
}
