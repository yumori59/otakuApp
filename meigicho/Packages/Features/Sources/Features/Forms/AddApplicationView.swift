import SwiftUI

/// 申込追加画面。実体は `ApplicationFormView(mode: .create)`（T4 でリファクタ抽出）。
///
/// このファイル自体は `AdGatekeeperTests`（AC-AD-27・禁止画面ソース走査）が
/// パスをハードコードして走査しているため、ファイルとして残す（広告枠を参照しないことの検証対象）。
struct AddApplicationView: View {
    var body: some View {
        ApplicationFormView(mode: .create)
    }
}
