import SwiftUI

/// Items grouped by the receipt (or charge) they came from: one card per shop visit, tap to open it and see the lines.
/// A visit with a single line is just that line. Hold a card and drag it to move everything in it at once; in Select mode
/// the card's tick selects its whole group.
struct ReceiptGroupedList: View {
    let items: [ItemView]
    @Binding var selecting: Bool
    @Binding var selected: Set<String>
    let onOpen: (ItemView) -> Void
    @State private var open = Set<String>()

    private struct Group: Identifiable {
        let id: String
        let items: [ItemView]
        var date: Date? { items.compactMap(\.date).max() }
        var merchant: String { items.first.map { $0.isVirtual ? $0.name : ($0.merchant ?? "Unknown store") } ?? "" }
        var total: Double { items.reduce(0) { $0 + ($1.personalSGD ?? 0) } }
    }

    private var groups: [Group] {
        let keyed = Dictionary(grouping: items) { item -> String in
            if let receipt = item.receipt { return "r-\(receipt.persistentModelID.hashValue)" }
            return item.id   // a charge with no receipt is a group of one
        }
        return keyed.map { Group(id: $0.key, items: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(groups) { group in
                if group.items.count == 1, let only = group.items.first { single(only) }
                else { card(group) }
            }
        }
    }

    private func single(_ item: ItemView) -> some View {
        let isSelected = selected.contains(item.id)
        return ItemRow(item: item, selecting: selecting, selected: isSelected)
            .onTapGesture { if selecting { toggle([item.id]) } else { onOpen(item) } }
            .draggable(selecting && isSelected ? Array(selected).joined(separator: "\n") : item.id) { ItemRow(item: item).frame(width: 320).opacity(0.95) }
    }

    private func card(_ group: Group) -> some View {
        let ids = group.items.map(\.id)
        let allSelected = ids.allSatisfy(selected.contains)
        let isOpen = open.contains(group.id)
        let tops = group.items.filter { item in item.parentID == nil || !ids.contains(item.parentID!) }
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if selecting {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20)).foregroundStyle(allSelected ? Theme.accent : Theme.mutedLine)
                }
                Text(group.date.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                    .font(.rounded(11, .bold)).foregroundStyle(Theme.muted).frame(width: 42, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.merchant).font(.rounded(15, .semibold)).lineLimit(1)
                    Text("\(group.items.count) items").font(.rounded(12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 6)
                Text(Money.string(group.total)).font(.rounded(15, .bold))
                if !selecting { Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted).rotationEffect(.degrees(isOpen ? 90 : 0)) }
            }
            .padding(12).contentShape(Rectangle())
            .onTapGesture {
                if selecting { toggle(ids) }
                else { withAnimation(.snappy(duration: 0.2)) { if isOpen { open.remove(group.id) } else { open.insert(group.id) } } }
            }
            .draggable(selecting && allSelected ? Array(selected).joined(separator: "\n") : ids.joined(separator: "\n")) {
                Text("\(group.merchant) · \(group.items.count) items").font(.rounded(13, .semibold)).padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(radius: 4)
            }
            if isOpen || selecting {
                VStack(spacing: 6) {
                    ForEach(tops) { item in
                        let isSelected = selected.contains(item.id)
                        ItemRow(item: item, children: group.items.filter { $0.parentID == item.id }, selecting: selecting, selected: isSelected)
                            .onTapGesture { if selecting { toggle([item.id]) } else { onOpen(item) } }
                            .draggable(selecting && isSelected ? Array(selected).joined(separator: "\n") : item.id) { ItemRow(item: item).frame(width: 320).opacity(0.95) }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(allSelected && selecting ? Theme.accent : Theme.line, lineWidth: allSelected && selecting ? 2 : 1) }
    }

    private func toggle(_ ids: [String]) {
        if ids.allSatisfy(selected.contains) { ids.forEach { selected.remove($0) } } else { ids.forEach { selected.insert($0) } }
    }
}
