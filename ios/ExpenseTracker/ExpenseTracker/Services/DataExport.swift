import Foundation
import SwiftData
import UIKit

/// Everything on this phone as one JSON file (photos and receipt images included), and the way back in: a backup, or a move
/// to another device. Nothing is sent anywhere - the file is handed to the share sheet and goes where you put it.
@MainActor
enum DataExport {
    struct Backup: Codable {
        var version = 1
        var exportedAt = Date()
        var categories: [CategoryRecord] = []
        var trips: [TripRecord] = []
        var receipts: [ReceiptRecord] = []
        var transactions: [TransactionRecord] = []
        var rules: [RuleRecord] = []
        var accounts: [AccountRecord] = []
        var moneyInLabels: [LabelRecord] = []
        var reconciliations: [ReconRecord] = []
        var checkpoints: [CheckpointRecord] = []
        var totalBudget: Double?
        var sharedCosts: [SharedCostRecord] = []
        /// relative path -> the file's bytes
        var files: [String: Data] = [:]
    }
    struct CategoryRecord: Codable { var id: Int; var name: String; var colorHex: String?; var icon: String?; var budgetSGD: Double?; var kindRaw: String; var sortOrder: Int; var parent: Int? }
    struct TripRecord: Codable { var id: Int; var name: String; var startDate: Date?; var endDate: Date?; var isActive: Bool; var isDemo: Bool; var colorHex: String?; var emoji: String? }
    struct ShareRecord: Codable { var person: String; var amount: Double?; var percentage: Double? }
    struct LineRecord: Codable {
        var uid: String; var position: Int; var name: String; var originalName: String?; var price: Double; var quantity: Double?
        var translatedText: String?; var originalPrice: Double?; var discount: Double?; var isDeposit: Bool; var parentUID: String?
        var photoPath: String?; var tags: [String]; var splitModeRaw: String; var shares: [ShareRecord]; var category: Int?
    }
    struct ReceiptRecord: Codable {
        var id: Int; var merchant: String?; var merchantOriginal: String?; var date: Date?; var currency: String?; var total: Double?; var tax: Double?
        var statusRaw: String; var suggestedCategory: String?; var ocrConfidence: Double?; var rawText: String?; var sourceImagePath: String?
        var isDemo: Bool; var trip: Int?; var items: [LineRecord]; var waivedGap: Double?; var visitCategory: Int?
    }
    struct TransactionRecord: Codable {
        var uid: String; var createdAt: Date; var date: Date?; var transactionDescription: String?; var amountSGD: Double?; var localAmount: Double?
        var localCurrency: String?; var matchStatusRaw: String?; var matchNote: String?; var transactionTypeRaw: String; var userNote: String?
        var reimbursementAmount: Double?; var incomeLabel: String?; var sourceRaw: String; var isOutflow: Bool; var isDemo: Bool
        var matchedReceipt: Int?; var trip: Int?; var refundsReceipt: Int?; var payee: String?
    }
    struct SharedCostRecord: Codable { var uid: String; var createdAt: Date; var title: String; var amountSGD: Double; var date: Date?; var remark: String?; var person: String?; var category: Int?; var trip: Int? }
    struct RuleRecord: Codable { var name: String; var category: Int?; var displayName: String? }
    struct AccountRecord: Codable { var key: String; var name: String; var kindRaw: String; var number: String?; var sortOrder: Int }
    struct LabelRecord: Codable { var name: String; var sortOrder: Int }
    struct ReconRecord: Codable { var createdAt: Date; var reconciledOn: Date; var actualSGD: Double; var impliedSGD: Double?; var untrackedSGD: Double; var knownThrough: Date?; var accountRaw: String; var isDemo: Bool }
    struct CheckpointRecord: Codable { var recordedAt: Date; var reachedAt: Date; var paidTotal: Double; var receivedTotal: Double; var coveredItemIDs: [String]; var coveredReimbursementIDs: [String] }

    struct ImportError: LocalizedError { var errorDescription: String? }

    private static func all<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }

    // MARK: export

    static func backupData(from context: ModelContext) throws -> Data {
        var backup = Backup()
        let categories = all(Category.self, context)
        let categoryIndex = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.persistentModelID, $0) })
        backup.categories = categories.enumerated().map { i, c in
            CategoryRecord(id: i, name: c.name, colorHex: c.colorHex, icon: c.icon, budgetSGD: c.budgetSGD, kindRaw: c.kindRaw, sortOrder: c.sortOrder,
                           parent: c.parent.flatMap { categoryIndex[$0.persistentModelID] })
        }
        let trips = all(Trip.self, context)
        let tripIndex = Dictionary(uniqueKeysWithValues: trips.enumerated().map { ($1.persistentModelID, $0) })
        backup.trips = trips.enumerated().map { i, t in
            TripRecord(id: i, name: t.name, startDate: t.startDate, endDate: t.endDate, isActive: t.isActive, isDemo: t.isDemo, colorHex: t.colorHex, emoji: t.emoji)
        }
        var paths = Set<String>()
        let receipts = all(Receipt.self, context)
        let receiptIndex = Dictionary(uniqueKeysWithValues: receipts.enumerated().map { ($1.persistentModelID, $0) })
        backup.receipts = receipts.enumerated().map { i, r in
            if let p = r.sourceImagePath, !p.isEmpty { paths.insert(p) }
            let items = r.lineItems.sorted { $0.position < $1.position }.map { l -> LineRecord in
                if let p = l.photoPath, !p.isEmpty { paths.insert(p) }
                return LineRecord(uid: l.uid, position: l.position, name: l.name, originalName: l.originalName, price: l.price, quantity: l.quantity,
                                  translatedText: l.translatedText, originalPrice: l.originalPrice, discount: l.discount, isDeposit: l.isDeposit,
                                  parentUID: l.parentUID, photoPath: l.photoPath, tags: l.tags, splitModeRaw: l.splitModeRaw,
                                  shares: l.shares.map { ShareRecord(person: $0.person, amount: $0.amount, percentage: $0.percentage) },
                                  category: l.category.flatMap { categoryIndex[$0.persistentModelID] })
            }
            return ReceiptRecord(id: i, merchant: r.merchant, merchantOriginal: r.merchantOriginal, date: r.date, currency: r.currency, total: r.total, tax: r.tax,
                                 statusRaw: r.statusRaw, suggestedCategory: r.suggestedCategory, ocrConfidence: r.ocrConfidence, rawText: r.rawText,
                                 sourceImagePath: r.sourceImagePath, isDemo: r.isDemo, trip: r.trip.flatMap { tripIndex[$0.persistentModelID] }, items: items, waivedGap: r.waivedGap, visitCategory: r.visitCategory.flatMap { categoryIndex[$0.persistentModelID] })
        }
        backup.transactions = all(YouTripTransaction.self, context).map { t in
            TransactionRecord(uid: t.uid, createdAt: t.createdAt, date: t.date, transactionDescription: t.transactionDescription, amountSGD: t.amountSGD,
                              localAmount: t.localAmount, localCurrency: t.localCurrency, matchStatusRaw: t.matchStatusRaw, matchNote: t.matchNote,
                              transactionTypeRaw: t.transactionTypeRaw, userNote: t.userNote, reimbursementAmount: t.reimbursementAmount,
                              incomeLabel: t.incomeLabel, sourceRaw: t.sourceRaw, isOutflow: t.isOutflow, isDemo: t.isDemo,
                              matchedReceipt: t.matchedReceipt.flatMap { receiptIndex[$0.persistentModelID] }, trip: t.trip.flatMap { tripIndex[$0.persistentModelID] },
                              refundsReceipt: t.refundsReceipt.flatMap { receiptIndex[$0.persistentModelID] }, payee: t.payee)
        }
        backup.rules = all(ItemRule.self, context).map { RuleRecord(name: $0.name, category: $0.category.flatMap { categoryIndex[$0.persistentModelID] }, displayName: $0.displayName) }
        backup.accounts = all(BankAccount.self, context).map { AccountRecord(key: $0.key, name: $0.name, kindRaw: $0.kindRaw, number: $0.number, sortOrder: $0.sortOrder) }
        backup.moneyInLabels = all(MoneyInLabel.self, context).map { LabelRecord(name: $0.name, sortOrder: $0.sortOrder) }
        backup.reconciliations = all(BalanceReconciliation.self, context).map {
            ReconRecord(createdAt: $0.createdAt, reconciledOn: $0.reconciledOn, actualSGD: $0.actualSGD, impliedSGD: $0.impliedSGD, untrackedSGD: $0.untrackedSGD,
                        knownThrough: $0.knownThrough, accountRaw: $0.accountRaw, isDemo: $0.isDemo)
        }
        backup.checkpoints = all(BalanceCheckpoint.self, context).map {
            CheckpointRecord(recordedAt: $0.recordedAt, reachedAt: $0.reachedAt, paidTotal: $0.paidTotal, receivedTotal: $0.receivedTotal,
                             coveredItemIDs: $0.coveredItemIDs, coveredReimbursementIDs: $0.coveredReimbursementIDs)
        }
        backup.sharedCosts = all(SharedCost.self, context).map { c in
            SharedCostRecord(uid: c.uid, createdAt: c.createdAt, title: c.title, amountSGD: c.amountSGD, date: c.date, remark: c.remark, person: c.person,
                             category: c.category.flatMap { categoryIndex[$0.persistentModelID] }, trip: c.trip.flatMap { tripIndex[$0.persistentModelID] })
        }
        backup.totalBudget = UserDefaults.standard.double(forKey: "totalBudget") > 0 ? UserDefaults.standard.double(forKey: "totalBudget") : nil
        for path in paths {
            let url = URL.documentsDirectory.appending(path: path)
            guard let image = UIImage(contentsOfFile: url.path) else { continue }
            // pictures are re-saved as modest JPEGs so the backup stays a sensible size
            let longest = max(image.size.width, image.size.height), scale = longest > 1800 ? 1800 / longest : 1
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let data = resized.jpegData(compressionQuality: 0.75) { backup.files[path] = data }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    /// Writes the backup to a temporary file ready for the share sheet.
    static func makeBackupFile(from context: ModelContext) throws -> URL {
        let data = try backupData(from: context)
        let name = "ExpenseTracker-backup-\(Date().formatted(.iso8601.year().month().day())).json"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: restore

    /// Replaces everything on this phone with the backup's contents.
    static func restore(_ data: Data, into context: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data) else { throw ImportError(errorDescription: "That isn’t an Expense Tracker backup.") }
        guard backup.version <= 1 else { throw ImportError(errorDescription: "This backup is from a newer version of the app.") }

        Actions.eraseEverything(in: context)
        for c in all(Category.self, context) { context.delete(c) }                // the starter tree is replaced by the backup's own
        for a in all(BankAccount.self, context) { context.delete(a) }
        for l in all(MoneyInLabel.self, context) { context.delete(l) }

        var categories: [Int: Category] = [:]
        for r in backup.categories {
            let c = Category(name: r.name, parent: nil, colorHex: r.colorHex, icon: r.icon, kind: CategoryKind(rawValue: r.kindRaw) ?? .normal, sortOrder: r.sortOrder)
            c.budgetSGD = r.budgetSGD
            context.insert(c)
            categories[r.id] = c
        }
        for r in backup.categories { if let parent = r.parent { categories[r.id]?.parent = categories[parent] } }
        var trips: [Int: Trip] = [:]
        for r in backup.trips {
            let t = Trip(name: r.name, startDate: r.startDate, endDate: r.endDate, isActive: r.isActive, colorHex: r.colorHex, emoji: r.emoji)
            t.isDemo = r.isDemo
            context.insert(t)
            trips[r.id] = t
        }
        var receipts: [Int: Receipt] = [:]
        for r in backup.receipts {
            let receipt = Receipt(merchant: r.merchant, merchantOriginal: r.merchantOriginal, date: r.date, currency: r.currency, total: r.total, tax: r.tax,
                                  status: ReviewStatus(rawValue: r.statusRaw) ?? .needsReview, suggestedCategory: r.suggestedCategory, ocrConfidence: r.ocrConfidence,
                                  rawText: r.rawText, sourceImagePath: r.sourceImagePath, trip: r.trip.flatMap { trips[$0] })
            receipt.isDemo = r.isDemo
            receipt.waivedGap = r.waivedGap
            receipt.visitCategory = r.visitCategory.flatMap { categories[$0] }
            context.insert(receipt)
            receipts[r.id] = receipt
            for l in r.items {
                let item = LineItem(name: l.name, price: l.price, quantity: l.quantity, translatedText: l.translatedText, originalPrice: l.originalPrice,
                                    discount: l.discount, isDeposit: l.isDeposit, tags: l.tags, category: l.category.flatMap { categories[$0] })
                item.uid = l.uid; item.position = l.position; item.originalName = l.originalName; item.parentUID = l.parentUID
                item.photoPath = l.photoPath; item.splitModeRaw = l.splitModeRaw
                item.receipt = receipt
                context.insert(item)
                for s in l.shares {
                    let share = LineItemShare(person: s.person, amount: s.amount, percentage: s.percentage)
                    context.insert(share)
                    item.shares.append(share)
                }
            }
        }
        for r in backup.transactions {
            let t = YouTripTransaction(date: r.date, description: r.transactionDescription, amountSGD: r.amountSGD, localAmount: r.localAmount, localCurrency: r.localCurrency,
                                       transactionType: TransactionType(rawValue: r.transactionTypeRaw) ?? .expense, trip: r.trip.flatMap { trips[$0] })
            t.uid = r.uid; t.createdAt = r.createdAt; t.matchStatusRaw = r.matchStatusRaw; t.matchNote = r.matchNote; t.userNote = r.userNote
            t.reimbursementAmount = r.reimbursementAmount; t.incomeLabel = r.incomeLabel; t.sourceRaw = r.sourceRaw; t.isOutflow = r.isOutflow; t.isDemo = r.isDemo; t.payee = r.payee
            t.matchedReceipt = r.matchedReceipt.flatMap { receipts[$0] }
            t.refundsReceipt = r.refundsReceipt.flatMap { receipts[$0] }
            context.insert(t)
        }
        for r in backup.rules { context.insert(ItemRule(name: r.name, category: r.category.flatMap { categories[$0] }, displayName: r.displayName)) }
        for r in backup.accounts {
            context.insert(BankAccount(key: r.key, name: r.name, kind: AccountKind(rawValue: r.kindRaw) ?? .bank, number: r.number, sortOrder: r.sortOrder))
        }
        for r in backup.moneyInLabels { context.insert(MoneyInLabel(name: r.name, sortOrder: r.sortOrder)) }
        for r in backup.reconciliations {
            let b = BalanceReconciliation(reconciledOn: r.reconciledOn, actualSGD: r.actualSGD, impliedSGD: r.impliedSGD, untrackedSGD: r.untrackedSGD,
                                          knownThrough: r.knownThrough, account: Account(rawValue: r.accountRaw))
            b.createdAt = r.createdAt; b.isDemo = r.isDemo
            context.insert(b)
        }
        for r in backup.checkpoints {
            let c = BalanceCheckpoint(reachedAt: r.reachedAt, paidTotal: r.paidTotal, receivedTotal: r.receivedTotal, coveredItemIDs: r.coveredItemIDs, coveredReimbursementIDs: r.coveredReimbursementIDs)
            c.recordedAt = r.recordedAt
            context.insert(c)
        }
        UserDefaults.standard.set(backup.totalBudget ?? 0, forKey: "totalBudget")
        for r in backup.sharedCosts {
            let c = SharedCost(title: r.title, amountSGD: r.amountSGD, date: r.date, remark: r.remark, person: r.person,
                               category: r.category.flatMap { categories[$0] }, trip: r.trip.flatMap { trips[$0] })
            c.uid = r.uid; c.createdAt = r.createdAt
            context.insert(c)
        }
        for (path, bytes) in backup.files {
            let url = URL.documentsDirectory.appending(path: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: url)
        }
        try context.save()
        AccountSeeder.ensureDefaults(in: context)
        CategorySeeder.seedIfNeeded(in: context)
    }
}
