import SwiftUI
import SwiftData

@main
struct ExpenseTrackerApp: App {
    // One shared SwiftData container for the whole app, persisted to disk in the app's own sandbox -
    // this is what makes the data survive app restarts (and the weekly free-signing reinstall).
    let container: ModelContainer = {
        let schema = Schema([
            Category.self, Trip.self, Receipt.self, LineItem.self, LineItemShare.self,
            YouTripTransaction.self, BalanceReconciliation.self, BalanceCheckpoint.self, ItemRule.self,
            MoneyInLabel.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        CategorySeeder.seedIfNeeded(in: container.mainContext)
        CategorySeeder.applySubColorsOnce(in: container.mainContext)
        return container
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
