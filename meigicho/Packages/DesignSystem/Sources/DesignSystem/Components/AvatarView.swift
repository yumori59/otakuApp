import SwiftUI

public struct AvatarView: View {
    let initial: String
    let colorHex: String
    let imageURL: URL?
    let size: CGFloat

    /// - Parameters:
    ///   - name:      表示名。先頭 1 文字をイニシャルとして使う。
    ///   - colorHex:  イニシャル背景色（`#RRGGBB` または `RRGGBB`）。
    ///   - imageURL:  アバター画像 URL。`nil` のときはイニシャル表示。
    ///   - size:      外径 (pt)。既定 44。
    public init(name: String, colorHex: String, imageURL: URL? = nil, size: CGFloat = 44) {
        self.initial = String(name.prefix(1))
        self.colorHex = colorHex
        self.imageURL = imageURL
        self.size = size
    }

    private var font: Font {
        // size == 44 のときは従来どおり bodyBold (16pt bold)。
        // それ以外は size の 38% の太字（ProfileCard で 66pt にしたとき scaleEffect(1.5) 相当に揃える）。
        size == 44 ? DSFont.bodyBold : .system(size: size * 0.38, weight: .bold)
    }

    public var body: some View {
        ZStack {
            // イニシャル + 色を常にベースに置く（読み込み中・失敗時のプレースホルダー）
            Color(hexString: colorHex)
            Text(initial)
                .font(font)
                .foregroundStyle(.white)
            // 画像が指定されているときだけ AsyncImage を重ねる
            if let url = imageURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
