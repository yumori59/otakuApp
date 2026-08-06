import SwiftUI

public struct SegmentedPicker<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    @Environment(\.themeStore) private var theme

    public init(options: [(value: T, label: String)], selection: Binding<T>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(DSFont.caption)
                        .foregroundStyle(selection == option.value ? theme.primary : DS.Gray.g600)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selection == option.value ? DS.surface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
        .padding(3)
        .background(DS.Gray.g100)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .padding(.bottom, 16)
    }
}
