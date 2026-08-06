import Foundation

public enum DateFormatting {
    private static let calendar = Calendar.jst

    private static let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    public static func daysUntil(from today: Date, to target: Date) -> Int {
        let start = calendar.startOfDay(for: today)
        let end = calendar.startOfDay(for: target)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    public static func formatDate(_ date: Date?, withWeekday: Bool = true) -> String {
        guard let date else { return "未設定" }
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return "未設定" }
        var result = "\(year)年\(month)月\(day)日"
        if withWeekday, let weekday = comps.weekday {
            let wd = weekdaySymbols[(weekday - 1) % 7]
            result += "(\(wd))"
        }
        return result
    }

    public static func formatDateShort(_ date: Date?) -> String {
        guard let date else { return "未定" }
        let comps = calendar.dateComponents([.month, .day], from: date)
        guard let month = comps.month, let day = comps.day else { return "未定" }
        return "\(month)/\(day)"
    }

    public static func formatYen(_ amount: Int) -> String {
        "¥\(amount.formatted())"
    }

    public static func today() -> Date {
        calendar.startOfDay(for: .now)
    }
}
