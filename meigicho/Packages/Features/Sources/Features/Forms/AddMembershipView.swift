import SwiftUI

/// 会員情報追加画面。実体は `MembershipFormView(mode: .create(identityID:))`（TE-5 でリファクタ抽出）。
///
/// このファイル自体は `AdGatekeeperTests`（AC-AD-27・禁止画面ソース走査）が
/// パスをハードコードして走査しているため、ファイルとして残す（広告枠を参照しないことの検証対象）。
struct AddMembershipView: View {
    let identityID: UUID

    var body: some View {
        MembershipFormView(mode: .create(identityID: identityID))
    }
}
