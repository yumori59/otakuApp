import SwiftUI

public struct SectionHeader: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(DSFont.captionBold)
            .foregroundStyle(DS.Gray.g600)
            .tracking(0.3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .padding(.horizontal, 4)
    }
}

public struct BigTitle: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DSFont.bigTitle)
                .foregroundStyle(DS.Gray.g900)
                .padding(.top, 16)
                .padding(.bottom, subtitle == nil ? 14 : 4)
            if let subtitle {
                Text(subtitle)
                    .font(DSFont.caption)
                    .foregroundStyle(DS.Gray.g600)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

public struct EmptyStateView: View {
    let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        Text(message)
            .font(DSFont.caption)
            .foregroundStyle(DS.Gray.g400)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
    }
}

public struct CardList<Content: View>: View {
    @ViewBuilder let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Gray.g200, lineWidth: 1)
        )
    }
}

public struct ListRow: View {
    let avatarInitial: String
    let avatarColor: String
    let title: String
    let subtitle: String
    let meta: String?
    let trailing: AnyView?
    let action: () -> Void

    public init(
        avatarInitial: String,
        avatarColor: String,
        title: String,
        subtitle: String,
        meta: String? = nil,
        trailing: (any View)? = nil,
        action: @escaping () -> Void
    ) {
        self.avatarInitial = avatarInitial
        self.avatarColor = avatarColor
        self.title = title
        self.subtitle = subtitle
        self.meta = meta
        self.trailing = trailing.map { AnyView($0) }
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: avatarInitial, colorHex: avatarColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DSFont.bodyBold)
                        .foregroundStyle(DS.Gray.g900)
                    Text(subtitle)
                        .font(DSFont.caption)
                        .foregroundStyle(DS.Gray.g600)
                        .lineLimit(2)
                    if let meta {
                        Text(meta)
                            .font(DSFont.caption)
                            .foregroundStyle(DS.Gray.g400)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Gray.g400)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}
