import SwiftUI
import SwiftData

/// The category drill-down (Food -> Cooking Ingredients -> Meat -> Chicken): semi-proportional tiles for the
/// children, then the transactions underneath. Tiles are drop targets - long-press an item and drag it onto one.
struct CategoryView: View {
    let target: CategoryTarget
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.breakdown
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var openItemID: String?
    @State private var movePicker = false
    @State private var editing = false
    @State private var addingChild = false

    enum Tab { case breakdown, transactions }

    var body: some View {
        WithLedger { ledger in content(ledger) }
            .navigationBarTitleDisplayMode(.inline)
    }

    private func scopeItems(_ ledger: Ledger) -> [ItemView] {
        switch target.scope {
        case .month(let month): return ledger.items(in: month.firstDay...month.lastDay.addingTimeInterval(86_399))
        case .trip(let trip): return ledger.items(in: nil, trip: trip)
        }
    }

    private func tree(_ ledger: Ledger) -> CategoryTree {
        switch target.scope {
        case .month(let month): return ledger.categoryTree(range: month.firstDay...month.lastDay.addingTimeInterval(86_399))
        case .trip(let trip): return ledger.categoryTree(trip: trip)
        }
    }

    private func node(_ tree: CategoryTree) -> CategoryNode? {
        if let category = target.category { return tree.node(for: category) }
        if let owner = target.unsortedOf {
            let own = tree.node(for: owner)
            return CategoryNode(category: nil, unsortedOf: owner, name: "Unsorted in \(owner.name)", icon: "?", kind: .normal, isUnsorted: true,
                                colorHex: owner.effectiveColorHex, budget: nil, ownSGD: own?.ownSGD ?? 0, totalSGD: own?.ownSGD ?? 0, count: own?.count ?? 0, children: [])
        }
        return CategoryNode(category: nil, unsortedOf: nil, name: "Unsorted", icon: "?", kind: .normal, isUnsorted: true, colorHex: "a9a39a", budget: nil,
                            ownSGD: tree.unsortedSGD, totalSGD: tree.unsortedSGD, count: tree.unsortedCount, children: [])
    }

    private func belongs(_ item: ItemView) -> Bool {
        if let category = target.category { return item.category?.pathIDs.contains(category.persistentModelID) ?? false }
        if let owner = target.unsortedOf { return item.category?.persistentModelID == owner.persistentModelID }
        return item.category == nil
    }

    @ViewBuilder
    private func content(_ ledger: Ledger) -> some View {
        let tree = tree(ledger)
        if let node = node(tree) {
            let items = scopeItems(ledger).filter { !$0.isDeposit && ($0.personalSGD ?? 1) > 0 && belongs($0) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let share = tree.totalSGD > 0 ? node.totalSGD / tree.totalSGD * 100 : 0
            Screen {
                hero(node, share: share)
                if !node.isUnsorted {
                    SegmentedTabs(options: [(Tab.breakdown, "Breakdown"), (Tab.transactions, "Transactions")], selection: $tab)
                }
                if tab == .transactions && !node.isUnsorted {
                    itemSection(items, ledger, limit: nil)
                } else {
                    breakdown(node, items, ledger)
                }
            }
            .navigationTitle(node.name)
            .toolbar { toolbar(node, ledger, items) }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar(items, ledger) } }
            .sheet(isPresented: Binding(get: { openItemID != nil }, set: { if !$0 { openItemID = nil } })) {
                if let id = openItemID { ItemSheet(itemID: id) }
            }
            .sheet(isPresented: $movePicker) {
                CategoryPicker(title: "Move to…", teach: true) { category, remember, similar in
                    let moving = ledger.items.filter { selected.contains($0.id) }
                    Actions.assignCategory(moving, to: category, alsoSimilar: similar, remember: remember, ledger: ledger, in: context)
                    toaster.show("Moved \(moving.count) item\(moving.count == 1 ? "" : "s") to \(category?.name ?? "Unsorted")")
                    selecting = false; selected = []
                }
            }
            .sheet(isPresented: $editing) { if let category = node.category { CategoryEditSheet(category: category, parent: nil, onDeleted: { dismiss() }) } }
            .sheet(isPresented: $addingChild) { CategoryEditSheet(category: nil, parent: node.category) }
        } else {
            Screen { EmptyCard("That category is gone", "It may have been deleted.") }
        }
    }

    private func hero(_ node: CategoryNode, share: Double) -> some View {
        let color = Color(hex: node.colorHex)
        let scopeLabel: String = {
            switch target.scope { case .month(let m): m.label; case .trip(let t): t.name }
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                IconTile(symbol: node.icon, color: color, size: 52)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Money.whole(node.totalSGD)).font(.rounded(30, .heavy))
                    Text(node.isUnsorted ? "real spending, not sorted yet" : "\(share < 10 ? String(format: "%.1f", share) : String(Int(share.rounded())))% of your spending")
                        .font(.rounded(13)).foregroundStyle(Theme.muted)
                    Text(scopeLabel).font(.rounded(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            if let budget = node.budget, case .month = target.scope {
                ProgressView(value: min(node.totalSGD, budget), total: budget).tint(node.totalSGD > budget ? Theme.bad : Theme.good)
                Text("of \(Money.whole(budget)) budget").font(.rounded(12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    @ViewBuilder
    private func breakdown(_ node: CategoryNode, _ items: [ItemView], _ ledger: Ledger) -> some View {
        let tiles = node.children.filter { !($0.totalSGD <= 0 && ($0.kind == .misc || $0.isUnsorted)) }
        if tiles.isEmpty {
            EmptyCard(node.isUnsorted ? "These items are in the right area, but not placed any deeper yet. Long-press one to move it."
                                       : "This is the lowest level.",
                      node.isUnsorted ? nil : "Add sub-categories from the ⋯ menu if you want to split it further.")
            dropTray(node, ledger)
        } else {
            TilesView(nodes: tiles, scope: target.scope, ledger: ledger)
        }
        SectionTitle(tiles.isEmpty ? "Transactions" : "Recent transactions") {
            if tiles.isEmpty == false && items.count > 6 { Button("See all") { tab = .transactions }.font(.rounded(13, .semibold)) }
        }
        itemSection(items, ledger, limit: tiles.isEmpty ? nil : 6)
    }

    /// At the lowest level there are no tiles to drop onto, so offer the parent and siblings as targets.
    @ViewBuilder
    private func dropTray(_ node: CategoryNode, _ ledger: Ledger) -> some View {
        let parent = node.category?.parent ?? node.unsortedOf
        let siblings = (node.category?.parent?.children ?? []).filter { $0.persistentModelID != node.category?.persistentModelID }.sorted { $0.sortOrder < $1.sortOrder }
        if parent != nil || !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Long-press an item, then drop it on:").font(.rounded(12)).foregroundStyle(Theme.muted)
                FlowChips(parent: parent, siblings: siblings, ledger: ledger)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.mutedLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
        }
    }

    @ViewBuilder
    private func itemSection(_ items: [ItemView], _ ledger: Ledger, limit: Int?) -> some View {
        if items.isEmpty { Text("No transactions yet.").font(.rounded(13)).foregroundStyle(Theme.muted) }
        else {
            ItemList(items: limit.map { Array(items.prefix($0)) } ?? items, selecting: $selecting, selected: $selected) { openItemID = $0.id }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ node: CategoryNode, _ ledger: Ledger, _ items: [ItemView]) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(selecting ? "Done selecting" : "Select items", systemImage: "checkmark.circle") { selecting.toggle(); if !selecting { selected = [] } }
                if node.category != nil {
                    Button("Edit category", systemImage: "pencil") { editing = true }
                    Button("Add sub-category", systemImage: "plus") { addingChild = true }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func selectionBar(_ items: [ItemView], _ ledger: Ledger) -> some View {
        HStack {
            Text("\(selected.count) selected").font(.rounded(15, .bold))
            Spacer()
            Button("Move to…") { movePicker = true }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            Button("Done") { selecting = false; selected = [] }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
    }
}

/// Chips that accept dropped items: the parent ("↑ Meat") and the siblings.
private struct FlowChips: View {
    let parent: Category?
    let siblings: [Category]
    let ledger: Ledger
    var body: some View {
        FlowLayout(spacing: 8) {
            if let parent { DropChip(title: "↑ \(parent.name)", category: parent, ledger: ledger) }
            ForEach(siblings.prefix(10)) { DropChip(title: $0.name, category: $0, ledger: ledger) }
        }
    }
}

private struct DropChip: View {
    let title: String
    let category: Category
    let ledger: Ledger
    @State private var targeted = false
    var body: some View {
        Text(title).font(.rounded(13, .semibold)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(targeted ? Theme.accentSoft : Theme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(targeted ? Theme.accent : Theme.mutedLine, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [4, 3])) }
            .modifier(CategoryDrop(category: category, ledger: ledger, targeted: $targeted))
    }
}

/// Wraps its children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Tiles

struct TilesView: View {
    let nodes: [CategoryNode]
    let scope: CategoryTarget.Scope
    let ledger: Ledger

    var body: some View {
        let rects = TileLayout.layout(nodes.map(\.totalSGD))
        let height = min(420, 150 + CGFloat(max(2, (nodes.count + 1) / 2)) * 62)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.index) { r in
                    let node = nodes[r.index]
                    Tile(node: node, scope: scope, ledger: ledger)
                        .frame(width: geo.size.width * r.w, height: geo.size.height * r.h)
                        .offset(x: geo.size.width * r.x, y: geo.size.height * r.y)
                }
            }
        }
        .frame(height: height)
    }
}

private struct Tile: View {
    let node: CategoryNode
    let scope: CategoryTarget.Scope
    let ledger: Ledger
    @State private var targeted = false

    private var color: Color {
        if node.isUnsorted || node.kind == .misc { return Theme.miscColor }
        if node.kind == .grocery { return Color(hex: "8ab8ff") }
        if node.category?.parent == nil { return Color(hex: node.colorHex) }
        return Theme.stablePastel(node.name)
    }

    var body: some View {
        let zero = node.totalSGD <= 0
        NavigationLink(value: Route.category(CategoryTarget(category: node.category, unsortedOf: node.unsortedOf, scope: scope))) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(node.isUnsorted ? Theme.segBg : color.opacity(zero ? 0.12 : 0.32))
                if node.isUnsorted { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.mutedLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.rounded(14, .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text(Money.whole(node.totalSGD)).font(.rounded(zero ? 15 : 19, .heavy)).foregroundStyle(zero ? Theme.muted : Theme.text)
                    if node.kind == .grocery { Label("no receipts", systemImage: "doc.text").font(.rounded(11)).foregroundStyle(Theme.muted) }
                }.padding(10)
                if let icon = node.category?.icon, node.kind == .normal, !node.isUnsorted {
                    // only when there's room: in a narrow tile the icon would sit on top of the name
                    GeometryReader { geo in
                        if geo.size.width > 130 { Text(icon).font(.system(size: 16)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8) }
                    }
                }
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent, lineWidth: 3) } }
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CategoryDrop(category: node.category ?? node.unsortedOf, ledger: ledger, targeted: $targeted))
    }
}

extension Theme {
    private static let pastels = ["7fd6a4", "ffb98a", "c5a3ff", "9ecbff", "ffd76b", "ff9fb2", "b7e06a", "8fe0e0"].map { Color(hex: $0) }
    /// A stable colour for a sub-category (Swift's own hashing changes every launch, so sum the characters).
    static func stablePastel(_ name: String) -> Color {
        pastels[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % pastels.count]
    }
}
