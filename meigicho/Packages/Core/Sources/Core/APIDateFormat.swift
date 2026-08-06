import Foundation

/// API 契約の日付変換（`contract-mapping.md` §2.1）。
///
/// - date-only（`joined_on` / `renewal_on` / `event_date` / `applied_on` / `result_on`）は
///   **JST 00:00 の `Date`** として扱う。端末のタイムゾーン設定に依存しない（E-10）。
/// - datetime（`created_at` / `starts_at` など）は ISO8601。
///   フラクショナル秒はあってもなくても解釈できる。
public enum APIDateFormat {
    private static let jstCalendar = Calendar.jst

    // MARK: - date-only

    /// `"2026-08-20"` → JST 2026-08-20 00:00 の `Date`。解釈できなければ nil。
    public static func dateOnly(from string: String) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        guard let date = jstCalendar.date(from: comps) else { return nil }
        // "2026-13-01" のような繰り上がりを弾く（Calendar は黙って翌年に送るため）
        let check = jstCalendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }

    /// `Date` → `"2026-08-20"`（JST 基準）。
    public static func dateOnlyString(from date: Date) -> String {
        let comps = jstCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    // MARK: - datetime

    // ISO8601DateFormatter は Sendable ではないため、生成後は不変のまま
    // NSLock で直列化して共有する（毎回生成するとリスト取得時のコストが無視できない）。
    private static let formatterLock = NSLock()

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601（フラクショナル秒あり / なしの両方）→ `Date`。
    public static func dateTime(from string: String) -> Date? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    /// `Date` → ISO8601 UTC ミリ秒（`onboarded_at` / `expires_at` の送信用）。
    public static func dateTimeString(from date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return fractionalFormatter.string(from: date)
    }
}
