import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Item rows

enum ItemFormat {
    static func amount(_ item: ItemView) -> (text: String, estimated: Bool) {
        if let sgd = item.personalSGD { return (Money.string(sgd, estimated: item.estimated), item.estimated) }
        return ("\(item.currency ?? "") \(String(format: "%.2f", item.price))".trimmingCharacters(in: .whitespaces), true)
    }
}

struct ItemRow: View {
    let item: ItemView

    /// "paid to Nicha" for a line that belongs to a payment sent from DBS or PayLah.
    private func paidTo(_ item: ItemView) -> String? {
        guard let t = item.transaction, t.isOutflow, t.transactionType == .expense, t.account != .youtrip else { return nil }
        let who = (t.transactionDescription ?? "").replacingOccurrences(of: "PayNow to ", with: "")
        return "paid to \(who)"
    }
    /// Bottle deposits paid with this item, shown as small lines under it.
    var children: [ItemView] = []
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
                (Text(item.name + ((item.quantity ?? 1) != 1 ? " ×\(item.quantity!.formatted())" : "")) + (item.lineItem?.photoPath != nil ? Text("  ") + Text(Image(systemName: "camera.fill")).font(.system(size: 12)).foregroundColor(Theme.muted) : Text(""))).font(.rounded(15, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(item.sharedCostID != nil ? (item.merchant ?? "") : (item.isVirtual ? "no receipt" : (item.merchant ?? "Unknown store"))).font(.rounded(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    if item.splitMode != .mine { MiniChip(text: (item.othersSGD ?? 0) > 0 ? "paid \(Money.whole(item.othersSGD ?? 0)) for others" : "paid for others", style: .paid) }
                    if let trip = item.trip { MiniChip(text: trip.name, style: .trip) }
                }
                if let paid = paidTo(item) {
                    // money sent to someone (PayNow / PayLah): the lines came from a breakdown of that payment, and tapping opens it
                    Label(paid, systemImage: "arrow.up.right").font(.rounded(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                ForEach(children) { child in
                    HStack(spacing: 4) { Glyph(symbol: Art.pant, size: 11); Text("\(child.name) · \(ItemFormat.amount(child).text)") }.font(.rounded(12)).foregroundStyle(Theme.muted)
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
            ForEach(topLevel) { item in
                let isSelected = selected.contains(item.id)
                ItemRow(item: item, children: items.filter { $0.parentID == item.id }, selecting: selecting, selected: isSelected)
                    .onTapGesture {
                        if selecting { if isSelected { selected.remove(item.id) } else { selected.insert(item.id) } }
                        else { onOpen(item) }
                    }
                    .draggable(payload(for: item)) { ItemRow(item: item).frame(width: 320).opacity(0.95) }
            }
        }
    }

    /// A deposit paid with a drink is shown inside that drink's row, not as a row of its own.
    private var topLevel: [ItemView] {
        let ids = Set(items.map(\.id))
        return items.filter { $0.parentID == nil || !ids.contains($0.parentID!) }
    }

    /// Drag payload: the ids being moved, newline-separated plain text.
    private func payload(for item: ItemView) -> String {
        (selecting && selected.contains(item.id) ? Array(selected) : [item.id]).joined(separator: "\n")
    }
}

/// "Select" toggle for a list of items: shown in the section header next to its title.
struct SelectButton: View {
    @Binding var selecting: Bool
    @Binding var selected: Set<String>
    var body: some View {
        Button(selecting ? "Done" : "Select") { selecting.toggle(); if !selecting { selected = [] } }
            .font(.rounded(13, .semibold))
    }
}

/// While selecting, a bar along the bottom to move every ticked item into a category in one go.
struct ItemSelectionBar: ViewModifier {
    @Binding var selecting: Bool
    @Binding var selected: Set<String>
    let ledger: Ledger
    var allIDs: [String] = []
    @Environment(\.modelContext) private var context
    @Environment(Toaster.self) private var toaster
    @State private var picking = false
    @State private var confirmDelete = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Text("\(selected.count) selected").font(.rounded(15, .bold))
                        Spacer()
                        if !allIDs.isEmpty {
                            Button(selected.count == allIDs.count ? "None" : "All") { selected = selected.count == allIDs.count ? [] : Set(allIDs) }.buttonStyle(.bordered)
                        }
                        Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.bordered).tint(Theme.bad)
                            .disabled(selected.isEmpty || !ledger.items.contains { selected.contains($0.id) && $0.lineItem != nil })
                        Button("Move to…") { picking = true }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
                }
            }
            .confirmationDialog("Delete the selected lines?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let n = Actions.deleteLines(ledger.items.filter { selected.contains($0.id) }, in: context)
                    toaster.show("Deleted \(n) line\(n == 1 ? "" : "s")"); selecting = false; selected = []
                }
            } message: { Text("Only lines read from a receipt can be deleted. A charge with no receipt stays.") }
            .sheet(isPresented: $picking) {
                CategoryPicker(title: "Move to…", teach: true) { category, remember, similar in
                    let moving = ledger.items.filter { selected.contains($0.id) }
                    Actions.assignCategory(moving, to: category, alsoSimilar: similar, remember: remember, ledger: ledger, in: context)
                    toaster.show(recategorisedMessage(moving.count, to: category?.name))
                    selecting = false; selected = []
                }
            }
    }
}

extension View {
    func itemSelection(selecting: Binding<Bool>, selected: Binding<Set<String>>, ledger: Ledger, all: [ItemView] = []) -> some View {
        modifier(ItemSelectionBar(selecting: selecting, selected: selected, ledger: ledger, allIDs: all.map(\.id)))
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
            toaster.show(recategorisedMessage(moving.count, to: category?.name))
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
    @State private var renaming = false
    @State private var editingPrice = false
    @State private var priceText = ""
    @State private var confirmDelete = false
    @State private var photoPick: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var viewingPhoto = false

    var body: some View {
        WithLedger { ledger in
            if let item = ledger.items.first(where: { $0.id == itemID }) { sheet(item, ledger) }
            else {
                // the item was moved or removed while this was open (a drag recategorises it, which can give it a new id):
                // there's nothing to show, so close rather than leave a blank sheet
                Color.clear.onAppear { dismiss() }
            }
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
                    if let printed = item.lineItem?.originalName, printed.lowercased() != item.name.lowercased() {
                        Text("As printed: \(printed)").font(.rounded(13)).foregroundStyle(Theme.muted)
                    }
                    Rows {
                        if !item.isVirtual {
                            Button { renaming = true } label: {
                                MenuRow("Name", hint: "Rename it so your history reads the way you think of it") { Text(item.name).font(.rounded(14)).foregroundStyle(Theme.muted).lineLimit(1) }
                            }.buttonStyle(.plain)
                        }
                        Button { pickingCategory = true } label: {
                            MenuRow("Category") { CategoryChip(category: item.category, confidence: item.confidence, full: true) }
                        }.buttonStyle(.plain)
                        if item.sharedCostID == nil && !item.id.hasPrefix("unacc-") { photoRow(item) }
                        if item.lineItem != nil {
                            Button { priceText = String(format: "%.2f", item.price); editingPrice = true } label: {
                                MenuRow("Price", hint: "Fix it if the receipt was read wrong") { Text("\(item.currency ?? "SGD") \(String(format: "%.2f", item.price))").font(.rounded(14)).foregroundStyle(Theme.muted) }
                            }.buttonStyle(.plain)
                        }
                        if item.confidence == .suggested, let category = item.category {
                            Button {
                                Actions.acceptSuggestions([item], ledger: ledger, in: context); toaster.show("Confirmed"); dismiss()
                            } label: { MenuRow("Yes, it’s \(category.name)", chevron: false) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }.foregroundStyle(Theme.accent) }
                                .buttonStyle(.plain)
                        }
                        if item.sharedCostID == nil && !item.id.hasPrefix("unacc-") {
                            Button { pickingTrip = true } label: { MenuRow("Trip") { Text(item.trip?.name ?? "None").font(.rounded(14)).foregroundStyle(Theme.muted) } }.buttonStyle(.plain)
                        }
                        if let trip = item.trip, item.sharedCostID != nil || item.id.hasPrefix("unacc-") {
                            NavigationLink(value: Route.reimbursementLog(trip)) { MenuRow("Open the reimbursement log", hint: "Edit or delete this cost there") }.buttonStyle(.plain)
                        }
                        if let t = item.transaction {
                            NavigationLink(value: Route.split(t)) { MenuRow("Split / paid for others") }.buttonStyle(.plain)
                            NavigationLink(value: Route.transaction(t)) { MenuRow("Open transaction") }.buttonStyle(.plain)
                        } else if let r = item.receipt {
                            NavigationLink(value: Route.receipt(r)) { MenuRow("Open receipt") }.buttonStyle(.plain)
                        }
                        if item.lineItem != nil {
                            Button { confirmDelete = true } label: { MenuRow("Delete this line", hint: "A line the receipt read twice, or that isn’t really there", chevron: false).foregroundStyle(Theme.bad) }.buttonStyle(.plain)
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
                toaster.show(category.map { "Recategorised to \($0.name)" } ?? "Cleared")
            }
        }
        .alert("Price", isPresented: $editingPrice) {
            TextField("0.00", text: $priceText).keyboardType(.decimalPad)
            Button("Save") {
                if let value = Double(priceText.replacingOccurrences(of: ",", with: ".")) {
                    do { try Actions.setLinePrice(item, to: value, in: context); toaster.show("Price updated") } catch { toaster.show(error.localizedDescription, error: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("In the receipt's own currency (\(item.currency ?? "SGD")).") }
        .confirmationDialog("Delete “\(item.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete this line", role: .destructive) { Actions.deleteLines([item], in: context); toaster.show("Deleted"); dismiss() }
        } message: { Text("Use this for a line the receipt read twice, or that isn’t on it. The receipt’s total stays as printed.") }
        .onChange(of: photoPick) { _, picked in
            guard let picked else { return }
            Task {
                defer { photoPick = nil }
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    Actions.setPhoto(image, on: item, in: context); toaster.show("Photo added")
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in Actions.setPhoto(image, on: item, in: context); toaster.show("Photo added") }.ignoresSafeArea()
        }
        .sheet(isPresented: $viewingPhoto) { if let image = ImageLoader.load(item.lineItem?.photoPath) { PhotoViewer(image: image) } }
        .sheet(isPresented: $renaming) {
            RenameSheet(current: item.name, printed: item.lineItem?.originalName ?? item.name) { name, remember in
                do { try Actions.rename(item, to: name, remember: remember, in: context); toaster.show(remember ? "Renamed. It will use this name next time too" : "Renamed") }
                catch { toaster.show(error.localizedDescription, error: true) }
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

/// Rename an item, optionally for good: every receipt that prints the same text will use the new name.
struct RenameSheet: View {
    let current: String
    let printed: String
    let onSave: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remember = true

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) } footer: { Text("Printed on the receipt as: \(printed)") }
                Section {
                    Toggle("Use this name whenever it appears again", isOn: $remember)
                } footer: { Text("Matches the exact printed text, and also renames the ones you’ve already added.") }
            }
            .navigationTitle("Rename item").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(name, remember); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = current }
        }
        .presentationDetents([.medium])
    }
}

extension ItemSheet {
    /// A photo to remember what exactly this was: a magnet bought somewhere, say. Optional, and most items never have one.
    @ViewBuilder
    fileprivate func photoRow(_ item: ItemView) -> some View {
        if let image = ImageLoader.load(item.lineItem?.photoPath) {
            HStack(spacing: 12) {
                Button { viewingPhoto = true } label: {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photo").font(.rounded(15))
                    Text("Tap to enlarge").font(.rounded(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Menu {
                    if CameraPicker.isAvailable { Button("Take a new photo", systemImage: "camera") { takingPhoto = true } }
                    PhotosPicker("Choose another", selection: $photoPick, matching: .images)
                    Button("Remove photo", systemImage: "trash", role: .destructive) { Actions.setPhoto(nil, on: item, in: context) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Theme.muted) }
            }.padding(.horizontal, 16).padding(.vertical, 10).rowDivider()
        } else {
            Menu {
                if CameraPicker.isAvailable { Button("Take a photo", systemImage: "camera") { takingPhoto = true } }
                PhotosPicker("Choose from photos", selection: $photoPick, matching: .images)
            } label: { MenuRow("Photo", hint: "Add one to remember what exactly this was") { Image(systemName: "camera").foregroundStyle(Theme.muted) } }
        }
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
                            MenuRow(trip.name, chevron: false) { if current?.persistentModelID == trip.persistentModelID { Image(systemName: "checkmark") } }
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
    @State private var creating: NewCategoryTarget?

    /// Where a new category is being added; `parent == nil` means at the top level.
    private struct NewCategoryTarget: Identifiable {
        let parent: Category?
        var id: String { parent.map { "\($0.persistentModelID.hashValue)" } ?? "top" }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ForEach(topLevel) { row($0, depth: 0) }
                    Button { creating = NewCategoryTarget(parent: nil) } label: {
                        Label("New top-level category", systemImage: "plus.circle").foregroundStyle(Theme.accent)
                    }
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
            // a category made from here is what you were about to pick, so it's chosen straight away
            .sheet(item: $creating) { target in
                CategoryEditSheet(category: nil, parent: target.parent, onCreated: { made in onPick(made, remember, similar); dismiss() })
            }
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
                Button { creating = NewCategoryTarget(parent: category) } label: {
                    Image(systemName: "plus.circle").frame(width: 28, height: 28).foregroundStyle(Theme.accent)
                }.buttonStyle(.borderless).accessibilityLabel("New category inside \(category.name)")
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
    @State private var colorHex: String?
    @State private var confirmDelete = false
    var onDeleted: (() -> Void)?
    /// Called with the new category after it's been created.
    var onCreated: ((Category) -> Void)?

    private static let swatches = Category.palette.map { String($0.dropFirst()) }
    private var topLevel: Bool { category == nil ? parent == nil : category!.parent == nil }
    private var parentName: String { (category?.parent ?? parent)?.name ?? "its parent" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Category name", text: $name) }
Section("Icon") {
                    HStack(spacing: 12) {
                        Glyph(symbol: icon.isEmpty ? nil : icon, size: 30).frame(width: 48, height: 48)
                            .background(Color(hex: colorHex ?? (category?.effectiveColorHex ?? parent?.effectiveColorHex ?? Category.fallbackColorHex)).opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        TextField("or type an emoji", text: Binding(get: { icon.hasPrefix(CategoryArt.prefix) ? "" : icon }, set: { icon = $0 })).font(.system(size: 22))
                    }
                    ForEach(CategoryArt.picker, id: \.group) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.group).font(.rounded(11, .semibold)).foregroundStyle(Theme.muted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(group.slugs, id: \.self) { slug in
                                        Button { icon = CategoryArt.symbol(slug: slug) } label: {
                                            Glyph(symbol: CategoryArt.symbol(slug: slug), size: 26).frame(width: 46, height: 46)
                                                .background(icon == CategoryArt.symbol(slug: slug) ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }.buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(Self.swatches, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                                .overlay { if colorHex?.lowercased().hasSuffix(hex.lowercased()) == true { Circle().stroke(Theme.text, lineWidth: 3) } }
                                .onTapGesture { colorHex = "#" + hex }
                        }
                    }
                    ColorPicker("Any other colour", selection: Binding(
                        get: { Color(hex: colorHex ?? (category?.effectiveColorHex ?? parent?.effectiveColorHex ?? Category.fallbackColorHex)) },
                        set: { colorHex = $0.hexString }), supportsOpacity: false).font(.rounded(14))
                    if !topLevel { Button("Same colour as \(parentName)") { colorHex = nil }.font(.rounded(14)) }
                } header: { Text("Colour") } footer: { Text(topLevel ? "This is the colour of its slice on the Home chart." : "Sub-categories can have their own colour, so vegetables and meat are easy to tell apart inside Food.") }
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
            }
        }
    }

    private func save() {
        do {
            if let category {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                category.name = trimmed
                category.icon = icon.isEmpty ? nil : icon
                if topLevel { if let colorHex { category.colorHex = colorHex } } else { category.colorHex = colorHex }
                try? context.save()
                toaster.show("Saved")
            } else {
                let made = try Actions.createCategory(name: name, parent: parent, icon: icon.isEmpty ? nil : icon, colorHex: colorHex, in: context)
                try? context.save()
                toaster.show("Category added")
                dismiss()
                onCreated?(made)
                return
            }
            dismiss()
        } catch { toaster.show(error.localizedDescription, error: true) }
    }
}
