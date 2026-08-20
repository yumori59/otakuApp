import SwiftUI

/// 名義追加画面。実体は `IdentityFormView(mode: .create)`（TE-4 でリファクタ抽出）。
///
/// このファイル自体は `AdGatekeeperTests`（AC-AD-27・禁止画面ソース走査）が
/// パスをハードコードして走査しているため、ファイルとして残す（広告枠を参照しないことの検証対象）。
struct AddIdentityView: View {
    let onSaved: (UUID) -> Void

    var body: some View {
        IdentityFormView(mode: .create, onSaved: onSaved)
    }
}
