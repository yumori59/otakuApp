import SwiftUI
import Core

public enum BadgeStyle {
    case ok, soon, warn

    var foreground: Color {
        switch self {
        case .ok: DS.success
        case .soon: DS.warning
        case .warn: DS.error
        }
    }

    var background: Color {
        switch self {
        case .ok: DS.successBG
        case .soon: DS.warningBG
        case .warn: DS.errorBG
        }
    }
}

public struct CountdownBadge: View {
    let text: String
    let style: BadgeStyle

    public init(text: String, style: BadgeStyle) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .font(DSFont.captionBold)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.background)
            .clipShape(Capsule())
    }

    public static func renewal(for date: Date, today: Date = DateFormatting.today()) -> CountdownBadge {
        let days = DateFormatting.daysUntil(from: today, to: date)
        if days < 0 { return CountdownBadge(text: "更新期限切れ", style: .warn) }
        if days <= 14 { return CountdownBadge(text: "あと\(days)日", style: .warn) }
        if days <= 30 { return CountdownBadge(text: "あと\(days)日", style: .soon) }
        return CountdownBadge(text: "\(DateFormatting.formatDateShort(date)) 更新", style: .ok)
    }

    public static func event(for date: Date, today: Date = DateFormatting.today()) -> CountdownBadge {
        let days = DateFormatting.daysUntil(from: today, to: date)
        if days < 0 { return CountdownBadge(text: "終了", style: .ok) }
        if days == 0 { return CountdownBadge(text: "本日", style: .warn) }
        if days <= 14 { return CountdownBadge(text: "あと\(days)日", style: .warn) }
        if days <= 30 { return CountdownBadge(text: "あと\(days)日", style: .soon) }
        return CountdownBadge(text: "あと\(days)日", style: .ok)
    }
}
