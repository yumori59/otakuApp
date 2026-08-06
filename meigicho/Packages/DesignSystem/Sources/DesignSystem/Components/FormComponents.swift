import SwiftUI
import Core

public struct FormSectionLabel: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(DSFont.captionBold)
            .foregroundStyle(DS.Gray.g600)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}

public struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }
}

public struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g600)
            content
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Gray.g200).frame(height: 1)
        }
    }
}

public struct FormTextField: View {
    let placeholder: String
    @Binding var text: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .font(DSFont.body)
            .padding(.vertical, 4)
    }
}

public struct FormHint: View {
    let text: String
    var isError = false

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var body: some View {
        Text(text)
            .font(DSFont.caption)
            .foregroundStyle(isError ? DS.error : DS.Gray.g500)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

public struct PrimaryButton: View {
    let title: String
    var isDestructive = false
    let action: () -> Void
    @Environment(\.themeStore) private var theme

    public init(_ title: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDestructive = isDestructive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(DSFont.bodyBold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isDestructive ? DS.error : theme.primary)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

public struct GoogleSignInButton: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(DS.Gray.g600)
                Text(title)
                    .font(DSFont.body)
                    .foregroundStyle(DS.Gray.g900)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

public struct LoginDivider: View {
    public init() {}

    public var body: some View {
        HStack {
            Rectangle().fill(DS.Gray.g200).frame(height: 1)
            Text("または")
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g400)
            Rectangle().fill(DS.Gray.g200).frame(height: 1)
        }
        .padding(.vertical, 16)
    }
}

public struct SwitchRow: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    public init(title: String, hint: String, isOn: Binding<Bool>) {
        self.title = title
        self.hint = hint
        self._isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DSFont.bodyBold)
                Text(hint).font(DSFont.caption).foregroundStyle(DS.Gray.g600)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }
}

public struct AddRowButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeStore) private var theme

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .foregroundStyle(theme.primary)
                Text(title)
                    .font(DSFont.body)
                    .foregroundStyle(theme.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

public struct MembershipCard: View {
    let fcName: String
    /// 会員番号の下 4 桁（任意）。平文の全桁は保持しない
    let memberNoLast4: String?
    /// 更新日は未設定がありうる
    let renewalOn: Date?
    /// 年会費は未設定がありうる
    let feeYen: Int?
    let today: Date

    public init(fcName: String, memberNoLast4: String?, renewalOn: Date?, feeYen: Int?, today: Date) {
        self.fcName = fcName
        self.memberNoLast4 = memberNoLast4
        self.renewalOn = renewalOn
        self.feeYen = feeYen
        self.today = today
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fcName).font(DSFont.bodyBold)
                    if let memberNoLast4, !memberNoLast4.isEmpty {
                        Text("No. \(memberNoLast4)").font(DSFont.caption).foregroundStyle(DS.Gray.g600)
                    }
                }
                Spacer()
                if let renewalOn {
                    CountdownBadge.renewal(for: renewalOn, today: today)
                }
            }
            HStack {
                Text("更新日 ").font(DSFont.caption).foregroundStyle(DS.Gray.g600)
                + Text(DateFormatting.formatDate(renewalOn)).font(DSFont.captionBold)
                Spacer()
                Text("年会費 ").font(DSFont.caption).foregroundStyle(DS.Gray.g600)
                + Text(feeYen.map { DateFormatting.formatYen($0) } ?? "未設定").font(DSFont.captionBold)
            }
        }
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }
}

public struct ProfileCard: View {
    let initial: String
    let colorHex: String
    let name: String
    let tag: String
    var stats: String?

    public init(initial: String, colorHex: String, name: String, tag: String, stats: String? = nil) {
        self.initial = initial
        self.colorHex = colorHex
        self.name = name
        self.tag = tag
        self.stats = stats
    }

    public var body: some View {
        VStack(spacing: 10) {
            AvatarView(name: initial, colorHex: colorHex)
                .scaleEffect(1.5)
                .padding(.bottom, 4)
            Text(name).font(DSFont.bodyBold)
            Text(tag).font(DSFont.caption).foregroundStyle(DS.Gray.g600)
            if let stats {
                Text(stats).font(DSFont.caption).foregroundStyle(DS.Gray.g500)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }
}

public struct TourActionButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @Environment(\.themeStore) private var theme

    public init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 14)) }
                Text(title).font(DSFont.caption)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).stroke(DS.Gray.g200, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

public struct ColorDot: View {
    let colorHex: String?

    public init(_ colorHex: String?) {
        self.colorHex = colorHex
    }

    public var body: some View {
        Circle()
            .fill(colorHex.map { Color(hexString: $0) } ?? DS.Gray.g300)
            .frame(width: 8, height: 8)
    }
}
