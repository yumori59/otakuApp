import Foundation

// `contract-mapping.md` §5 の protocol 8 本。
// **Domain は Foundation のみ import する。** URLSession / Security / SwiftData を持ち込まない（NFR-5 / IOS-5）。
// 実装は Network（`Remote*Repository`）と Domain/Preview（`InMemory*Repository`）の 2 系統。

public protocol AuthRepository: Sendable {
    // ソーシャル
    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthSession
    func signInWithGoogle(idToken: String, nonce: String?) async throws -> AuthSession

    // メール + パスワード
    func register(email: String, password: String) async throws -> AuthSession
    func login(email: String, password: String) async throws -> AuthSession
    /// Bearer 必須。**成功時にサーバーが refresh を全件失効させ、新しいペアを返す**（A5）。
    /// 戻り値を捨てると自分自身が次の refresh でログアウトする。
    func changePassword(current: String, new: String) async throws -> TokenPair
    /// 202 / ボディ無し。登録の有無に関わらず同じ応答（A4）。
    func requestPasswordReset(email: String) async throws
    /// 成功時に全件失効 + 新ペア。そのままログイン状態にする（A6）。
    func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthSession

    // トークン
    /// 回転式。返ってきた `refreshToken` を必ず保存し直す。
    func refresh(refreshToken: String) async throws -> TokenPair
    func logout(refreshToken: String) async throws

    /// `DELETE /v1/me`。204。**成功したらトークンとローカル状態を必ず破棄する**（`AuthStore` の責務）。
    /// - password: `auth_providers` に "email" がある場合のみ渡す（nil ならキー自体を送らない）
    /// - appleAuthorizationCode: Apple 失効用（Q2 = A のときのみ。nil ならキーを送らない）
    func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws
}

public protocol ProfileRepository: Sendable {
    func fetchMe() async throws -> MeSnapshot
    func updateMe(_ patch: ProfilePatch) async throws -> MeSnapshot
}

public protocol HomeRepository: Sendable {
    func fetchSummary() async throws -> HomeSummary
}

public protocol StatsRepository: Sendable {
    func fetchIdentityStats() async throws -> IdentityStatsSnapshot
}

public protocol IdentityRepository: Sendable {
    func list() async throws -> [Identity]
    func create(_ identity: Identity) async throws -> Identity
    func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity
    func delete(id: UUID) async throws
}

public protocol MembershipRepository: Sendable {
    func list() async throws -> [Membership]
    func create(_ membership: Membership) async throws -> Membership
    func update(id: UUID, _ patch: MembershipPatch) async throws -> Membership
    func delete(id: UUID) async throws
}

/// tours + events。**作成メソッドを持たない**（`POST /v1/tours` は存在しない = C3）。
public protocol CatalogRepository: Sendable {
    func listTours() async throws -> [Tour]
    func listEvents() async throws -> [EventEntity]
    func fetchEvent(id: UUID) async throws -> EventEntity
    func updateTour(id: UUID, _ patch: TourPatch) async throws -> Tour
    func updateEvent(id: UUID, _ patch: EventPatch) async throws -> EventEntity
}

public protocol ApplicationRepository: Sendable {
    /// `cursor` は不透明値。解釈も生成もしない（C7）。
    func listPage(limit: Int, cursor: String?) async throws -> ApplicationPage
    func create(_ draft: ApplicationDraft) async throws -> ApplicationEntry
    func update(id: UUID, _ patch: ApplicationPatch) async throws -> ApplicationEntry
    func delete(id: UUID) async throws
}

/// 共有リンク（オーナー側・Bearer 必須）。
public protocol ShareRepository: Sendable {
    func list() async throws -> [ShareLink]
    /// 発行時のみ token / url を受け取れる（C4）。
    ///
    /// `sharedWithAccountIDs` は **1 件以上必須**（`POST /v1/shares` のリクエストキーは
    /// `shared_with_account_ids` のまま）。存在しない ACC-ID が混ざると
    /// `.shareRecipientUnknown(accountIDs:)`、自分自身を含めると `.validation` で失敗し、
    /// **共有は作られない**（`api-contract-delta.md` §1 の判定順序）。
    func create(
        _ selection: ShareScopeSelection,
        maskMemberNo: Bool,
        sharedWithAccountIDs: [String]
    ) async throws -> IssuedShareLink
    /// `POST /v1/shares/:id/recipients`。**戻り値は追加後の全件**（差分ではない）。
    /// 既に招待済みの ACC-ID は冪等（`invitedAt` も更新されない）。
    func addRecipients(shareID: UUID, accountIDs: [String]) async throws -> [ShareRecipient]
    /// `DELETE /v1/shares/:id/recipients/:account_id`。204・冪等。
    /// **最後の 1 人を外しても成功する**（以後そのリンクは誰も開けない）。
    func removeRecipient(shareID: UUID, accountID: String) async throws
    func revoke(id: UUID) async throws
}

/// 共有ボード（受け取り側）。**Bearer 必須**（`GET|PATCH /v1/shares/received/:id`）。
///
/// 以前は「受け取った人はログインしていない前提」の公開経路（`/public/shares/:token`）だったが、
/// **その前提は廃止された**。開けるのは招待されたアカウントとオーナー本人だけで、
/// addressing は token ではなく `share_id`。実装は通常の `ApiClient`（Bearer）を使う。
///
/// 招待されていない `share_id` は **404 `.shareInvalid`** で返る（403 にしない = 存在を confirm しない）。
public protocol SharedBoardRepository: Sendable {
    func fetchBoard(shareID: UUID) async throws -> SharedBoard
    func updateItem(
        shareID: UUID,
        itemKey: String,
        rev: String,
        change: SharedItemChange
    ) async throws -> SharedBoardItem
}

/// 受信箱（**自分が招待された共有**・Bearer 必須）。`api-contract-delta.md` §4.1 / §4.4 / §4.5。
public protocol SharedInboxRepository: Sendable {
    /// `GET /v1/shares/received`。失効・期限切れ・非表示・自分がオーナーのものは含まれない。
    /// 招待 0 件でも空配列（エラーにしない）。
    func list() async throws -> [SharedInboxItem]
    /// `POST /v1/shares/received/redeem`。ディープリンクの token を `share_id` に交換する。
    ///
    /// - 招待済み / オーナー本人 → `share_id`
    /// - **招待されていない → `.shareNotInvited`**（契約上ここだけが 403 で存在を confirm する）
    /// - 未知 / 失効 / 期限切れ → `.shareInvalid`（3 者を区別しない）
    func redeem(token: String) async throws -> UUID
    /// `POST|DELETE /v1/shares/received/:id/hide`。204・冪等。
    /// 非表示はオーナーには見えない（Q3）。
    func setHidden(shareID: UUID, hidden: Bool) async throws
}

/// LWW 差分同期（`docs/04` §4）。実装は Network / 将来の SyncEngine。
public protocol SyncRepository: Sendable {
    func pull(_ request: SyncPullRequest) async throws -> SyncPullResult
    func push(mutations: [SyncMutation]) async throws -> SyncPushResult
}
