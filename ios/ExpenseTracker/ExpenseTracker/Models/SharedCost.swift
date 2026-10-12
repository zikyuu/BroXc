import Foundation
import SwiftData

/// The days a trip's reimbursement log is laid out in, newest first: every day of the trip, plus any other day a cost was dated to.
enum TripDays {
    static let maxDays = 62

    static func slots(trip: Trip, costs: [SharedCost]) -> [Date] {
        var days = Set(costs.compactMap { $0.date?.startOfDay })
        if let start = trip.startDate?.startOfDay {
            let end = max(trip.endDate?.startOfDay ?? start, start)
            var day = start
            while day <= end && days.count < maxDays {
                days.insert(day)
                guard let next = Dates.calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days.sorted(by: >)
    }

    /// "D2" for the second day of the trip, nil when the day is outside it or the trip has no start.
    static func dayNumber(_ day: Date, trip: Trip) -> Int? {
        guard let start = trip.startDate?.startOfDay else { return nil }
        let n = (Dates.calendar.dateComponents([.day], from: start, to: day.startOfDay).day ?? -1) + 1
        return n >= 1 ? n : nil
    }
}

/// Something someone else paid for that you owe your share of ("owe junyuen $14.21: medieval dinner"), logged by hand,
/// usually during a trip and before any money moves. It's real spending of yours from the day it happened. The payment
/// that later settles it is not spending again: it's checked against the log instead (see `Ledger.tripLog`).
@Model
final class SharedCost {
    var uid: String = UUID().uuidString
    var createdAt: Date = Date()
    /// What it was, in your own words ("D2 water", "bussing lunch").
    var title: String = ""
    /// Your share, in SGD. Always positive: it's what you owe.
    var amountSGD: Double = 0
    /// When it happened, if you know. Otherwise it's dated to the trip.
    var date: Date?
    var remark: String?
    /// Who paid for it, if you want to remember.
    var person: String?
    var category: Category?
    var trip: Trip?

    init(title: String, amountSGD: Double, date: Date? = nil, remark: String? = nil, person: String? = nil,
         category: Category? = nil, trip: Trip? = nil) {
        self.title = title
        self.amountSGD = amountSGD
        self.date = date
        self.remark = remark
        self.person = person
        self.category = category
        self.trip = trip
    }
}
