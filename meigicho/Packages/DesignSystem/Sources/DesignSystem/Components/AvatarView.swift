import SwiftUI

/// イニシャル＋テーマ色の円形アバター。
///
/// `imageURL` が非 nil のときはその画像を優先表示し、
/// 読み込み中・失敗時はイニシャルのプレースホルダーにフォールバックする（FR-AV-20）。
/// 既存の呼び出し元（`imageURL: nil`・`size: 44`）は見た目が変わらない（T-IOS3）。
public struct AvatarView: View {
    let initial: String
    let colorHex: String
    let imageURL: URL?
    let size: CGFloat

    public init(name: String, colorHex: String, imageURL: URL? = nil, size: CGFloat = 44) {
        self.initial = String(name.prefix(1))
        self.colorHex = colorHex
        self.imageURL = imageURL
        self.size = size
    }

    public var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    default:
                        placeholder
                    }
                }
                .frame(width: size, height: size)
            } else {
                placeholder
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Text(initial)
            .font(DSFont.bodyBold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hexString: colorHex))
            .clipShape(Circle())
    }
}
