import Foundation

extension Calendar {
    /// 日付のみのデータ（更新日・公演日・当落発表日）の正は **Asia/Tokyo 00:00**（`docs/05` §6）。
    public static let jst: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }()
}
