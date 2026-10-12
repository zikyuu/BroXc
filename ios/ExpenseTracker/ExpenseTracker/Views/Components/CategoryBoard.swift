import SwiftUI
import Charts

/// The shape of a tile's colour, shared by the donut slices and the tiles so a category is one colour everywhere.
func categoryTileColor(_ node: CategoryNode) -> Color {
    if node.isUnsorted || node.kind == .misc { return Theme.miscColor }
    if node.kind == .grocery { return Color(hex: "8ab8ff") }
    if node.category?.parent == nil || node.category?.colorHex != nil { return Color(hex: node.colorHex) }
    return Theme.stablePastel(node.name)
}

/// A category as a donut of its children, with the category in the middle. Touch a slice to see what it is; the legend
/// underneath opens it.
struct CategoryDonut: View {
    let node: CategoryNode
    let tiles: [CategoryNode]
    let scope: CategoryTarget.Scope
    let scopeLabel: String
    let share: Double
    @State private var selectedAngle: Double?

    private var selected: CategoryNode? {
        guard let angle = selectedAngle else { return nil }
        var running = 0.0
        for tile in tiles {
            running += max(tile.totalSGD, 0)
            if angle <= running { return tile }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 10) {
            Chart(tiles.filter { $0.totalSGD > 0 }) { tile in
                SectorMark(angle: .value("Spent", tile.totalSGD), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .cornerRadius(5)
                    .foregroundStyle(categoryTileColor(tile))
                    .opacity(selected == nil || selected?.id == tile.id ? 1 : 0.4)
                    .annotation(position: .overlay) {
                        // every slice carries its icon (a little smaller on a thin slice)
                        Glyph(symbol: tile.icon, size: tile.totalSGD / max(node.totalSGD, 1) < 0.08 ? 13 : 20)
                    }
            }
            .chartAngleSelection(value: $selectedAngle)
            .chartLegend(.hidden)
            .chartBackground { proxy in
                GeometryReader { geo in
                    if let anchor = proxy.plotFrame {
                        let frame = geo[anchor]
                        VStack(spacing: 1) {
                            Glyph(symbol: selected?.icon ?? node.icon, size: 22)
                            Text(selected?.name ?? node.name).font(.rounded(15, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                            Text(Money.whole(selected?.totalSGD ?? node.totalSGD)).font(.rounded(22, .heavy))
                            if selected == nil {
                                Text("\(share < 10 ? String(format: "%.1f", share) : String(Int(share.rounded())))% of spending").font(.rounded(11)).foregroundStyle(Theme.muted)
                            }
                        }
                        .frame(width: frame.width * 0.52)
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .frame(height: 250)
            Text(scopeLabel).font(.rounded(12)).foregroundStyle(Theme.muted)
            if let budget = node.budget, case .month = scope {
                ProgressView(value: min(node.totalSGD, budget), total: budget).tint(node.totalSGD > budget ? Theme.bad : Theme.good)
                Text("of \(Money.whole(budget)) budget").font(.rounded(12)).foregroundStyle(Theme.muted)
            }
            FlowLayout(spacing: 8) {
                ForEach(tiles.filter { $0.totalSGD > 0 }) { tile in
                    NavigationLink(value: Route.category(CategoryTarget(category: tile.category, unsortedOf: tile.unsortedOf, scope: scope))) {
                        HStack(spacing: 5) {
                            Glyph(symbol: tile.icon, size: 14)
                            Text("\(tile.name) \(Money.whole(tile.totalSGD))").font(.rounded(12, .medium)).foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surface, in: Capsule()).overlay { Capsule().strokeBorder(Theme.line) }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity)
        .background(categoryTileColor(node).opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// Each child category as a card: its sub-category breakdown, or (at the bottom of the tree) its own recent transactions. Hold a transaction and drag it onto another card
/// to move it there; tap a card's title to go inside it.
struct TileBoard: View {
    let nodes: [CategoryNode]
    let items: [ItemView]
    let scope: CategoryTarget.Scope
    let ledger: Ledger
    let onOpen: (ItemView) -> Void

    static let perTile = 3

    private func itemsIn(_ node: CategoryNode) -> [ItemView] {
        if node.isUnsorted { return items.filter { $0.category?.persistentModelID == node.unsortedOf?.persistentModelID } }
        guard let category = node.category else { return [] }
        return items.filter { $0.category?.pathIDs.contains(category.persistentModelID) ?? false }
    }

    var body: some View {
        // two columns, each new card going under the shorter one, since the cards differ in height
        var columns: [[CategoryNode]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for node in nodes {
            let count = itemsIn(node).count
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(node)
            if TileCard.breakdownRows(node).isEmpty {
                heights[column] += 64 + CGFloat(min(Self.perTile, count)) * 64 + (count > Self.perTile ? 28 : 0) + (count == 0 ? 28 : 0)
            } else {
                heights[column] += 64 + CGFloat(min(TileCard.maxRows, TileCard.breakdownRows(node).count)) * 30
            }
        }
        return HStack(alignment: .top, spacing: 10) {
            ForEach(0..<2, id: \.self) { index in
                VStack(spacing: 10) {
                    ForEach(columns[index]) { node in
                        TileCard(node: node, tileItems: itemsIn(node), scope: scope, ledger: ledger, onOpen: onOpen)
                    }
                }.frame(maxWidth: .infinity)
            }
        }
    }
}

private struct TileCard: View {
    let node: CategoryNode
    let tileItems: [ItemView]
    let scope: CategoryTarget.Scope
    let ledger: Ledger
    let onOpen: (ItemView) -> Void
    @State private var targeted = false

    private var route: Route { .category(CategoryTarget(category: node.category, unsortedOf: node.unsortedOf, scope: scope)) }

    static let maxRows = 5

    /// A category that has sub-categories with spending in them shows that breakdown (Meat, Vegetables, Fruit...) rather than
    /// a pile of individual transactions; transactions are shown only in a card with nothing deeper to break down into.
    static func breakdownRows(_ node: CategoryNode) -> [CategoryNode] {
        // only when something is actually filed deeper: a card whose spending all sits directly in it (nothing in Chicken,
        // Pork...) has no breakdown to show, so it shows the transactions themselves
        guard !node.isUnsorted, node.children.contains(where: { !$0.isUnsorted && $0.totalSGD > 0 }) else { return [] }
        return node.children.filter { $0.totalSGD > 0 }
    }

    var body: some View {
        let color = categoryTileColor(node)
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: route) {
                HStack(alignment: .top, spacing: 4) {
                    Glyph(symbol: node.icon, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.rounded(14, .bold)).lineLimit(2)
                        Text(Money.whole(node.totalSGD)).font(.rounded(19, .heavy)).foregroundStyle(node.totalSGD > 0 ? Theme.text : Theme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted).padding(.top, 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)

            let rows = Self.breakdownRows(node)
            if !rows.isEmpty {
                ForEach(rows.prefix(Self.maxRows)) { child in
                    NavigationLink(value: Route.category(CategoryTarget(category: child.category, unsortedOf: child.unsortedOf, scope: scope))) {
                        HStack(spacing: 7) {
                            Glyph(symbol: child.icon, size: 15)
                            Text(child.name).font(.rounded(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Money.whole(child.totalSGD)).font(.rounded(13, .bold)).foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plain)
                }
                if rows.count > Self.maxRows {
                    NavigationLink(value: route) { Text("+\(rows.count - Self.maxRows) more").font(.rounded(12, .semibold)).foregroundStyle(Theme.accent) }
                }
            } else {
                // a bottle deposit belongs to its drink: small text inside the same card, not a card of its own
                let ids = Set(tileItems.map(\.id))
                let tops = tileItems.filter { $0.parentID == nil || !ids.contains($0.parentID!) }
                ForEach(tops.prefix(TileBoard.perTile)) { item in
                    MiniItemCard(item: item, deposits: tileItems.filter { $0.parentID == item.id }, onOpen: onOpen)
                }
                if tops.count > TileBoard.perTile {
                    NavigationLink(value: route) { Text("See all \(tops.count)").font(.rounded(12, .semibold)).foregroundStyle(Theme.accent) }
                } else if tileItems.isEmpty {
                    Text("Drop items here").font(.rounded(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(node.isUnsorted ? Theme.segBg : color.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if node.isUnsorted { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.mutedLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            if targeted { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent, lineWidth: 3) }
        }
        .modifier(CategoryDrop(category: node.category ?? node.unsortedOf, ledger: ledger, targeted: $targeted))
    }
}

private struct MiniItemCard: View {
    let item: ItemView
    var deposits: [ItemView] = []
    let onOpen: (ItemView) -> Void

    var body: some View {
        let amount = ItemFormat.amount(item)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.date.map { $0.formatted(.dateTime.day().month(.abbreviated)).uppercased() } ?? "").font(.rounded(10, .bold)).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                Text(amount.text).font(.rounded(12, .bold)).foregroundStyle(amount.estimated ? Theme.muted : Theme.text)
            }
            Text(item.name).font(.rounded(13, .semibold)).lineLimit(1)
            Text(item.sharedCostID != nil ? (item.merchant ?? "") : (item.isVirtual ? "no receipt" : (item.merchant ?? ""))).font(.rounded(11)).foregroundStyle(Theme.muted).lineLimit(1)
            ForEach(deposits) { pant in
                HStack(spacing: 3) { Glyph(symbol: Art.pant, size: 9); Text("\(pant.name.lowercased()) \(ItemFormat.amount(pant).text)") }.font(.rounded(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: item.confidence == .suggested ? [3, 2] : [])) }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { onOpen(item) }
        .draggable(item.id) { MiniItemPreview(item: item) }
    }
}

private struct MiniItemPreview: View {
    let item: ItemView
    var body: some View {
        HStack { Text(item.name).font(.rounded(13, .semibold)).lineLimit(1); Text(ItemFormat.amount(item).text).font(.rounded(13, .bold)) }
            .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(radius: 4)
    }
}
