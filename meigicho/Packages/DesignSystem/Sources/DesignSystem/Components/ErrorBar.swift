import SwiftUI

/// 読み込み済みの画面で再取得に失敗したときに出す 1 行のエラーバー（`questions-requirements.md` Q11）。
///
/// `docs/05` §5 の「モーダルやアラートは絶対に出さない」に従い、画面内容はそのまま残す。
/// タップで再試行する。
public struct ErrorBar: View {
    let message: String
    let retry: (() -> Void)?

    public init(_ message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        Button {
            retry?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                Text(message)
                    .font(DSFont.caption)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if retry != nil {
                    Text("再試行").font(DSFont.captionBold)
                }
            }
            .foregroundStyle(DS.error)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.errorBG)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(retry == nil)
        .accessibilityLabel(retry == nil ? message : "\(message)。タップで再試行")
    }
}

#Preview {
    VStack(spacing: 0) {
        ErrorBar("最新の情報を取得できませんでした") {}
        ErrorBar("オフラインです。通信環境を確認してください")
    }
}
