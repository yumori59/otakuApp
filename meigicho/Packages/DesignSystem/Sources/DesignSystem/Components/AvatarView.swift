import SwiftUI

public struct AvatarView: View {
    let initial: String
    let colorHex: String

    public init(name: String, colorHex: String) {
        self.initial = String(name.prefix(1))
        self.colorHex = colorHex
    }

    public var body: some View {
        Text(initial)
            .font(DSFont.bodyBold)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color(hexString: colorHex))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
