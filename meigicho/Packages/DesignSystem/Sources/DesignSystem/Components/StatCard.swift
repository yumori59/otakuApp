import SwiftUI

public struct StatCard: View {
    let value: String
    let label: String
    @Environment(\.themeStore) private var theme

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    public var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(DSFont.statNum)
                .foregroundStyle(theme.primary)
                .monospacedDigit()
            Text(label)
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g600)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Gray.g200, lineWidth: 1)
        )
    }
}

public struct StatRow: View {
    let cards: [(value: String, label: String)]

    public init(cards: [(value: String, label: String)]) {
        self.cards = cards
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                StatCard(value: card.value, label: card.label)
            }
        }
    }
}
