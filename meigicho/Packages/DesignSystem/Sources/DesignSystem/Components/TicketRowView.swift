import SwiftUI

public struct StampView: View {
    public enum Status {
        case draft, applied, won, lost

        public var label: String {
            switch self {
            case .draft: "下書き"
            case .applied: "申込中"
            case .won: "当選"
            case .lost: "落選"
            }
        }

        var foreground: Color {
            switch self {
            case .won: DS.success
            case .lost: DS.Gray.g600
            case .draft: DS.Gray.g500
            case .applied: DS.warning
            }
        }

        var background: Color {
            switch self {
            case .won: DS.successBG
            case .lost: DS.Gray.g100
            case .draft: DS.Gray.g100
            case .applied: DS.warningBG
            }
        }
    }

    let status: Status

    public init(status: Status) {
        self.status = status
    }

    public var body: some View {
        Text(status.label)
            .font(DSFont.captionBold)
            .foregroundStyle(status.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status.background)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            .accessibilityLabel(status.label)
    }
}

public struct TagView: View {
    public enum Kind {
        case rep, companion

        var foreground: Color {
            switch self {
            case .rep: DS.Blue.b900
            case .companion: DS.Gray.g600
            }
        }

        var background: Color {
            switch self {
            case .rep: DS.Blue.b50
            case .companion: DS.Gray.g100
            }
        }
    }

    let text: String
    let kind: Kind

    public init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        Text(text)
            .font(DSFont.caption)
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kind.background)
            .clipShape(Capsule())
    }
}

public struct TicketRowView: View {
    let event: String
    let meta: String
    let tags: [TagView]
    let status: StampView.Status
    let stubText: String
    let action: () -> Void

    public init(
        event: String,
        meta: String,
        tags: [TagView],
        status: StampView.Status,
        stubText: String,
        action: @escaping () -> Void
    ) {
        self.event = event
        self.meta = meta
        self.tags = tags
        self.status = status
        self.stubText = stubText
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event)
                        .font(DSFont.bodyBold)
                        .foregroundStyle(DS.Gray.g900)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(DSFont.caption)
                        .foregroundStyle(DS.Gray.g600)
                    FlowLayout(spacing: 6) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                            tag
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    StampView(status: status)
                    Text(stubText)
                        .font(DSFont.caption)
                        .foregroundStyle(DS.Gray.g500)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 92)
                .padding(.vertical, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DS.Gray.g200)
                        .frame(width: 1.5)
                }
            }
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .stroke(DS.Gray.g200, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

/// タグを折り返し表示する簡易レイアウト
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
