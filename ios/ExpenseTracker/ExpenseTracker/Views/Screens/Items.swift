import SwiftUI
import SwiftData

// MARK: - Item rows

enum ItemFormat {
    static func amount(_ item: ItemView) -> (text: String, estimated: Bool) {
        if let sgd = item.personalSGD { return (Money.string(sgd, estimated: item.estimated), item.estimated) }
        return ("\(item.currency ?? "") \(String(format: "%.2f", item.price))".trimmingCharacters(in: .whitespaces), true)
    }
}

struct ItemRow: View {
    let item: ItemView
    var selecting = false
    var selected = false

    var body: some View {
        let amount = ItemFormat.amount(item)
        HStack(alignment: .top, spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? Theme.accent : Theme.mutedLine).padding(.top, 1)
            }
            Text(item.date.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                .font(.rounded(11, .bold)).foregroundStyle(Theme.muted).frame(width: 42, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name + ((item.quantity ?? 1) != 1 ? " ×\(item.quantity!.formatted())" : "")).font(.rounded(15, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(item.isVirtual ? "no receipt" : (item.merchant ?? "Unknown store")).font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    if item.splitMode != .mine { MiniChip(text: (item.othersSGD ?? 0) > 0 ? "paid \(Money.whole(item.othersSGD ?? 0)) for others" : "paid for others", style: .paid) }
                    if let trip = item.trip { MiniChip(text: trip.name, style: .trip) }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(amount.text).font(.rounded(15, .bold)).foregroundStyle(amount.estimated ? Theme.muted : Theme.text)
                CategoryChip(category: item.category, confidence: item.confidence)
            }
        }
        .padding(12)
        .background(selected ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: item.confidence == .suggested && !selected ? [4, 3] : []))
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A list of items that can be tapped (opens the item), selected (Select mode), and long-press-dragged onto a
/// category tile or chip, which re-categorises it. Dragging a selected item drags the whole selection.
struct ItemList: View {
    let items: [ItemView]
    @Binding var selecting: Bool
    @Binding var selected: Set<String>
    let onOpen: (ItemView) -> Void

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in
                let isSelected = selected.contains(item.id)
                ItemRow(item: item, selecting: selecting, selected: isSelected)
                    .onTapGesture {
                        if selecting { if isSelected { selected.remove(item.id) } else { selected.insert(item.id) } }
                        else { onOpen(item) }
                    }
                    .draggable(payload(for: item)) { ItemRow(item: item).frame(width: 320).opacity(0.95) }
            }
        }
    }

    /// Drag payload: the ids being moved, newline-separated plain text.
    private func payload(for item: ItemView) -> String {
        (selecting && selected.contains(item.id) ? Array(selected) : [item.id]).joined(separator: "\n")
    }
}

/// What dropping onto a tile/chip does: move the dragged items into that category.
struct CategoryDrop: ViewModifier {
    let category: Category?
    let ledger: Ledger
    @Binding var targeted: Bool
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster

    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { strings, _ in
            let ids = Set(strings.flatMap { $0.split(separator: "\n").map(String.init) })
            let moving = ledger.items.filter { ids.contains($0.id) }
            guard !moving.isEmpty else { return false }
            Actions.assignCategory(moving, to: category, ledger: ledger, in: context)
            toaster.show("Moved \(moving.count) item\(moving.count == 1 ? "" : "s") to \(category?.name ?? "Unsorted")")
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Item sheet

struct ItemSheet: View {
    let itemID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var pickingCategory = false
    @State private var pickingTrip = false

    var body: some View {
        WithLedger { ledger in
            if let item = ledger.items.first(where: { $0.id == itemID }) { sheet(item, ledger) }
            else { Text("This item no longer exists.").foregroundStyle(Theme.muted).padding() }
        }
    }

    private func sheet(_ item: ItemView, _ ledger: Ledger) -> some View {
        let amount = ItemFormat.amount(item)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(amount.text).font(.rounded(30, .heavy))
                        if let sgd = item.priceSGD, let personal = item.personalSGD, abs(sgd - personal) > 0.005 {
                            Text("of \(Money.string(sgd))").font(.rounded(13)).foregroundStyle(Theme.muted)
                        }
                        Text([item.isVirtual ? "No receipt yet" : item.merchant, item.date?.formatted(.dateTime.day().month(.abbreviated).year()),
                              (item.currency != nil && item.currency != "SGD") ? "\(item.currency!) \(String(format: "%.2f", item.price))" : nil]
                                .compactMap { $0 }.joined(separator: " · ")).font(.rounded(13)).foregroundStyle(Theme.muted)
                    }
                    Rows {
                        Button { pickingCategory = true } label: {
                            MenuRow("Category") { CategoryChip(category: item.category, confidence: item.confidence, full: true) }
                        }.buttonStyle(.plain)
                        if item.confidence == .suggested, let category = item.category {
                            Button {
                                Actions.acceptSuggestions([item], ledger: ledger, in: context); toaster.show("Confirmed"); dismiss()
                            } label: { MenuRow("Yes, it’s \(category.name)", chevron: false) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }.foregroundStyle(Theme.accent) }
                                .buttonStyle(.plain)
                        }
                        Button { pickingTrip = true } label: { MenuRow("Trip") { Text(item.trip?.name ?? "None").font(.rounded(14)).foregroundStyle(Theme.muted) } }.buttonStyle(.plain)
                        if let t = item.transaction {
                            NavigationLink(value: Route.split(t)) { MenuRow("Split / paid for others") }.buttonStyle(.plain)
                            NavigationLink(value: Route.transaction(t)) { MenuRow("Open transaction") }.buttonStyle(.plain)
                        } else if let r = item.receipt {
                            NavigationLink(value: Route.receipt(r)) { MenuRow("Open receipt") }.buttonStyle(.plain)
                        }
                    }.flushCard()
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .appDestinations()
        }
        .sheet(isPresented: $pickingCategory) {
            CategoryPicker(selected: item.category, allowClear: true, teach: true) { category, remember, similar in
                Actions.assignCategory([item], to: category, alsoSimilar: similar, remember: remember, ledger: ledger, in: context)
                toaster.show(category.map { "Moved to \($0.name)" } ?? "Cleared")
            }
        }
        .sheet(isPresented: $pickingTrip) {
            TripPicker(current: item.trip) { trip in
                if let t = item.transaction { Actions.assign(t, to: trip, in: context) }
                else if let r = item.receipt { Actions.assign(r, to: trip, in: context) }
                toaster.show("Trip updated")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Pickers

struct TripPicker: View {
    let current: Trip?
    let onPick: (Trip?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Trip.name) private var trips: [Trip]

    var body: some View {
        NavigationStack {
            ScrollView {
                Rows {
                    Button { onPick(nil); dismiss() } label: { MenuRow("No trip", chevron: false) { if current == nil { Image(systemName: "checkmark") } } }.buttonStyle(.plain)
                    ForEach(trips) { trip in
                        Button { onPick(trip); dismiss() } label: {
                            MenuRow("\(trip.emoji ?? "🧳") \(trip.name)", chevron: false) { if current?.persistentModelID == trip.persistentModelID { Image(systemName: "checkmark") } }
                        }.buttonStyle(.plain)
                    }
                }.flushCard().padding(16)
                if trips.isEmpty { Text("No trips yet. Create one from the Trip tab.").font(.rounded(13)).foregroundStyle(Theme.muted).padding() }
            }
            .screenBackground().navigationTitle("Which trip?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// A searchable, collapsible tree of the user's own categories.
struct CategoryPicker: View {
    var title = "Choose a category"
    var selected: Category?
    var allowClear = false
    var teach = false
    let onPick: (Category?, _ remember: Bool, _ similar: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var query = ""
    @State private var expanded: Set<PersistentIdentifier> = []
    @State private var remember = true
    @State private var similar = false

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ForEach(topLevel) { row($0, depth: 0) }
                } else {
                    ForEach(categories.filter { $0.path.joined(separator: " ").localizedCaseInsensitiveContains(query) }.sorted { $0.path.joined() < $1.path.joined() }) { category in
                        pick(category, subtitle: category.path.dropLast().joined(separator: " › "))
                    }
                }
                if teach {
                    Section {
                        Toggle("Remember this for next time", isOn: $remember)
                        Toggle("Also fix past items with the same name that I haven’t sorted", isOn: $similar)
                    }.font(.rounded(14))
                }
                if allowClear {
                    Section { Button("Clear (let the app guess)") { onPick(nil, false, false); dismiss() } }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .onAppear { if let selected { expanded = Set(selected.pathIDs.dropLast()) } }
        }
        .presentationDetents([.large])
    }

    private var topLevel: [Category] { categories.filter { $0.parent == nil }.sorted { $0.sortOrder < $1.sortOrder } }

    private func pick(_ category: Category, subtitle: String? = nil) -> some View {
        Button { onPick(category, remember, similar); dismiss() } label: {
            HStack(spacing: 10) {
                IconTile(symbol: category.icon, color: Color(hex: category.effectiveColorHex), size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(category.name).foregroundStyle(Theme.text)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.rounded(11)).foregroundStyle(Theme.muted) }
                }
                Spacer()
                if category.persistentModelID == selected?.persistentModelID { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
    }

    private func row(_ category: Category, depth: Int) -> AnyView {
        let kids = category.children.sorted { $0.sortOrder < $1.sortOrder }
        let open = expanded.contains(category.persistentModelID)
        return AnyView(Group {
            HStack(spacing: 4) {
                if kids.isEmpty { Color.clear.frame(width: 28, height: 28) }
                else {
                    Button {
                        if open { expanded.remove(category.persistentModelID) } else { expanded.insert(category.persistentModelID) }
                    } label: { Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).frame(width: 28, height: 28).foregroundStyle(Theme.muted) }
                        .buttonStyle(.borderless)
                }
                pick(category).buttonStyle(.borderless)
            }
            .padding(.leading, CGFloat(depth) * 18)
            if open { ForEach(kids) { row($0, depth: depth + 1) } }
        })
    }
}

// MARK: - Category editor

struct CategoryEditSheet: View {
    var category: Category?        // nil = creating
    var parent: Category?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var name = ""
    @State private var icon = ""
    @State private var budget = ""
    @State private var colorHex: String?
    @State private var confirmDelete = false
    var onDeleted: (() -> Void)?

    private static let emoji = ["🍴", "🛒", "🚆", "🛏️", "🎟️", "🛍️", "🎁", "🏠", "💊", "☕", "🍜", "🎮", "📚", "💼", "✈️", "🐶", "🎬", "💇", "📱", "🧾"]
    private static let swatches = ["ff8a75", "5d8df6", "7c83f5", "ffb066", "b36cf0", "f58bd0", "a5d86e", "4fd1a5", "c9a877", "f2c94c"]
    private var topLevel: Bool { category == nil ? parent == nil : category!.parent == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Category name", text: $name) }
                Section("Icon") {
                    TextField("🙂", text: $icon).font(.system(size: 28))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(Self.emoji, id: \.self) { e in Button(e) { icon = e }.font(.system(size: 26)).buttonStyle(.borderless) } }
                    }
                }
                if topLevel {
                    Section {
                        HStack { ForEach(Self.swatches, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                                .overlay { if colorHex?.lowercased().hasSuffix(hex) == true { Circle().stroke(Theme.text, lineWidth: 3) } }
                                .onTapGesture { colorHex = "#" + hex }
                        } }
                    } header: { Text("Colour") } footer: { Text("Colour stays the same everywhere, so this category is always easy to spot.") }
                }
                Section {
                    TextField("No budget", text: $budget).keyboardType(.decimalPad)
                } header: { Text("Monthly budget (optional)") } footer: { Text("Sets the green line on the spending map. Without one, your usual spending is the line.") }
                if let category {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: { Text("Delete this category") }
                    }
                    .confirmationDialog("Delete “\(category.name)”? Anything inside it moves up to \(category.parent?.name ?? "Unsorted"). Nothing is lost.",
                                        isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            let moved = Actions.deleteCategory(category, in: context)
                            toaster.show("Deleted. \(moved) item\(moved == 1 ? "" : "s") moved up."); dismiss(); onDeleted?()
                        }
                    }
                }
            }
            .navigationTitle(category == nil ? (parent.map { "New in \($0.name)" } ?? "New category") : "Edit \(category!.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(category == nil ? "Add" : "Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear {
                guard let category else { return }
                name = category.name; icon = category.icon ?? ""; colorHex = category.colorHex
                budget = category.budgetSGD.map { $0.formatted(.number.grouping(.never)) } ?? ""
            }
        }
    }

    private func save() {
        do {
            let budgetValue = Double(budget.trimmingCharacters(in: .whitespaces))
            if let category {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                category.name = trimmed
                category.icon = icon.isEmpty ? nil : icon
                category.budgetSGD = budgetValue
                if topLevel, let colorHex { category.colorHex = colorHex }
                try? context.save()
                toaster.show("Saved")
            } else {
                let made = try Actions.createCategory(name: name, parent: parent, icon: icon.isEmpty ? nil : icon, colorHex: colorHex, in: context)
                made.budgetSGD = budgetValue
                try? context.save()
                toaster.show("Category added")
            }
            dismiss()
        } catch { toaster.show(error.localizedDescription, error: true) }
    }
}
