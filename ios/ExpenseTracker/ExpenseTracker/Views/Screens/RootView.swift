import SwiftUI

enum AppTab: Hashable { case home, activity, trip, reimburse, more }

@MainActor @Observable
final class AppNavigation { var selectedTab = AppTab.home }

/// Maps every `Route` to its screen. Applied to each tab's NavigationStack (and to sheets that navigate).
struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .category(let target): CategoryView(target: target)
        case .transaction(let t): TransactionView(transaction: t)
        case .receipt(let r): ReceiptView(receipt: r)
        case .split(let t): SplitView(transaction: t)
        case .classify(let t): ClassifyView(transaction: t)
        case .breakdown(let t): BreakdownView(transaction: t)
        case .trip(let t): TripDetailView(trip: t)
        case .tripMode: TripModeView()
        case .search: SearchView()
        case .trends: TrendsView()
        case .review: ReviewView()
        case .balance: BalanceView()
        case .categories: CategoriesView()
        case .add: AddView()
        case .more: MoreView()
        }
    }
}

extension View {
    func appDestinations() -> some View { navigationDestination(for: Route.self) { RouteView(route: $0) } }
}

struct RootView: View {
    @State private var navigation = AppNavigation()
    @State private var toaster = Toaster()
    @State private var paths: [AppTab: [Route]] = [:]

    var body: some View {
        ZStack {
            TabView(selection: $navigation.selectedTab) {
                stack(.home) { HomeView() }.tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
                stack(.activity) { ActivityView() }.tabItem { Label("Activity", systemImage: "waveform.path.ecg") }.tag(AppTab.activity)
                stack(.trip) { TravelView() }.tabItem { Label("Trip", systemImage: "airplane") }.tag(AppTab.trip)
                stack(.reimburse) { ReimburseView() }.tabItem { Label("Reimburse", systemImage: "creditcard") }.tag(AppTab.reimburse)
                stack(.more) { MoreView() }.tabItem { Label("More", systemImage: "ellipsis") }.tag(AppTab.more)
            }
            .tint(Theme.accent)
            ToastOverlay()
        }
        .environment(navigation)
        .environment(toaster)
        .onAppear(perform: applyLaunchArguments)
    }

    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder _ root: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })) { root().appDestinations() }
    }

    /// Debug builds only: `-tab trip -route trends` opens straight onto a screen, for checking screens quickly.
    private func applyLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let tabs: [String: AppTab] = ["home": .home, "activity": .activity, "trip": .trip, "reimburse": .reimburse, "more": .more]
        let routes: [String: Route] = ["search": .search, "trends": .trends, "review": .review, "balance": .balance, "categories": .categories,
                                       "add": .add, "tripmode": .tripMode, "more": .more]
        if let name = value("-tab"), let tab = tabs[name] { navigation.selectedTab = tab }
        if let name = value("-route"), let route = routes[name] { paths[navigation.selectedTab, default: []].append(route) }
        #endif
    }
}
