import SwiftUI

/// A fixed set of "where is…?" answers for when you're lost, each with a button that goes straight there.
struct HelpView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
        var link: (title: String, route: Route)?
        var tab: (title: String, tab: AppTab)?
    }

    @Environment(AppNavigation.self) private var navigation

    private let entries: [Entry] = [
        Entry(question: "How do I add a receipt or my transactions?", answer: "Go to the Activity tab and tap the blue + button. Photograph a receipt (it’s read and translated on your phone), or choose a screenshot of your YouTrip, PayLah or DBS history: the app works out which one it is and skips anything you’ve already added.",
              tab: ("Open Activity", .activity)),
        Entry(question: "A receipt says “the items don’t add up”. What do I do?", answer: "The printed total is a checksum: the lines the camera read should add up to it. Open the receipt and tap “Add another photo” (better light, or just the part that was missed) or “Add the missing line”. Lines you already have are kept."),
        Entry(question: "How do I put something in a different category?", answer: "Several ways: tap an item and choose a category; hold a transaction and drag it onto another category’s card; or tap Select, tick a few, and use “Move to…”. In the picker, the + beside any category makes a new one inside it."),
        Entry(question: "How do I rename an item?", answer: "Tap the item, then Name. Choose “Use this name whenever it appears again” and every receipt that prints the same text will use your name from then on."),
        Entry(question: "What does the chart on Home show?", answer: "Each slice is a category. How far it reaches is your spending so far against what’s usual for this point in the month: past the dashed ring means you’re ahead of your usual pace. “At this pace” is a projection of the whole month from your rate so far. “Usual” is your average over earlier months, so it needs at least one."),
        Entry(question: "Where do I check my balances and add a bank account?", answer: "The chips at the top of Home show each account’s balance. Tap one to check or enter its balance, and tap + at the end to add an account. Press and hold a chip, then drag it, to reorder them.",
              link: ("Open balance check", .balance)),
        Entry(question: "What is “Needs a look”?", answer: "The app’s guesses: categories it suggested and receipt-to-charge links it isn’t sure about. Confirming is optional, but confirmed items count as sorted.",
              link: ("Open Needs a look", .review)),
        Entry(question: "How do I see how this month compares with usual?", answer: "The “Compared with usual” card on Home opens Trends: your monthly totals and this month’s pace against usual.",
              link: ("Open Trends", .trends)),
        Entry(question: "I paid for a friend, or a friend paid me back. Where does that go?", answer: "The Reimburse tab keeps what others owe you and what they’ve paid back. Mark a transaction “paid for others” (or split it) on its page, and mark money coming in as a reimbursement.",
              tab: ("Open Reimburse", .reimburse)),
        Entry(question: "How do I track a trip?", answer: "The Trip tab. Turn on Trip Mode and new receipts and charges join the trip automatically; you can also add one to a trip by hand, even after it’s over.",
              tab: ("Open Trip", .trip)),
        Entry(question: "I paid someone by PayNow for a shared bill (like a Tricount). How do I record what I actually spent?", answer: "Open that payment and tap “Break down into items”. List what you spent, with a category each, and choose a trip. The items are the same money as the payment, not extra."),
        Entry(question: "Why is a transaction missing?", answer: "Transfers between your own accounts show in both, and DBS can take a few days to post one. On the Balance check screen, “Moves between your accounts” lists any that are still waiting for the other half."),
        Entry(question: "Where is my data, and can I move it?", answer: "Only on this phone: no account, no cloud. Use “Export my data” in More to save a backup file (photos included), and “Import a backup” on another phone to load it. A phone installed from Xcode with a free account also needs re-installing every 7 days; your data survives that."),
    ]

    var body: some View {
        Screen {
            Text("Tap a question for the answer.").font(.rounded(13)).foregroundStyle(Theme.muted)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.answer).font(.rounded(14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            if let link = entry.link {
                                NavigationLink(value: link.route) { Text(link.title + " →").font(.rounded(14, .semibold)).foregroundStyle(Theme.accent) }
                            }
                            if let tab = entry.tab {
                                Button { navigation.selectedTab = tab.tab } label: { Text(tab.title + " →").font(.rounded(14, .semibold)).foregroundStyle(Theme.accent) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    } label: {
                        Text(entry.question).font(.rounded(15, .semibold)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).rowDivider()
                    .tint(Theme.muted)
                }
            }.flushCard()
        }
        .navigationTitle("Help").navigationBarTitleDisplayMode(.inline)
    }
}
