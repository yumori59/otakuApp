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
    func create(
        _ selection: ShareScopeSelection,
        maskMemberNo: Bool,
        sharedWithAccountIDs: [String]
    ) async throws -> IssuedShareLink
    func revoke(id: UUID) async throws
}

/// 共有ボード（受け取り側）。**Bearer を使わない。token が唯一の資格情報**（§5.1）。
/// 実装は `PublicApiClient` のみを使い、`ApiClient` / `TokenStore` を参照しない。
public protocol SharedBoardRepository: Sendable {
    func fetchBoard(token: String) async throws -> SharedBoard
    func updateItem(
        token: String,
        itemKey: String,
        rev: String,
        change: SharedItemChange
    ) async throws -> SharedBoardItem
}

/// LWW 差分同期（`docs/04` §4）。実装は Network / 将来の SyncEngine。
public protocol SyncRepository: Sendable {
    func pull(_ request: SyncPullRequest) async throws -> SyncPullResult
    func push(mutations: [SyncMutation]) async throws -> SyncPushResult
}
