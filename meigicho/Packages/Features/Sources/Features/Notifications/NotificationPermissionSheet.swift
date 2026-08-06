import SwiftUI
import DesignSystem
import Core

/// 会員情報保存後のプリパーミッション（`docs/05` §6）。
public struct NotificationPermissionSheet: View {
    let renewalDate: Date
    let onAccept: () async -> Void
    let onDefer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeStore) private var theme
    @State private var isRequesting = false

    public init(renewalDate: Date, onAccept: @escaping () async -> Void, onDefer: @escaping () -> Void) {
        self.renewalDate = renewalDate
        self.onAccept = onAccept
        self.onDefer = onDefer
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("更新日をお知らせしますか？")
                    .font(DSFont.bodyBold)
                Text("\(DateFormatting.formatDate(renewalDate)) の更新を、30日前・14日前・前日の朝9時にお知らせします。当落発表日も同様にお知らせできます。")
                    .font(DSFont.body)
                    .foregroundStyle(DS.Gray.g600)
                Spacer()
                PrimaryButton(isRequesting ? "設定中…" : "お知らせを受け取る") {
                    Task {
                        isRequesting = true
                        await onAccept()
                        isRequesting = false
                        dismiss()
                    }
                }
                .disabled(isRequesting)
                Button("あとで") {
                    onDefer()
                    dismiss()
                }
                .font(DSFont.body)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(20)
            .background(theme.bgApp)
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
