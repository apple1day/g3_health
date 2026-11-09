import Foundation

struct RecentWorkoutWindow {
    let start: Date
    let end: Date
    init(now: Date, calendar: Calendar = .current) {
        start = calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 86400)
        end = now
    }
    func containsCompletion(_ date: Date) -> Bool { date >= start && date <= end }
}
