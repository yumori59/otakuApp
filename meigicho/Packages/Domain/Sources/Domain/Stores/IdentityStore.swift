import Foundation
import Core

/// 名義 + 会員情報のストア（旧 `AppDataStore` の名義側）。
///
/// **名義またぎの集計（当選数・申込一覧）は `ApplicationStore` が持ち、
/// ここは結果を引数で受け取る**（相互参照を作らない）。
@MainActor
@Observable
public final class IdentityStore {
    public var identities: [Identity] = []
    public var memberships: [Membership] = []
    public var identitiesState: LoadState = .idle
    public var membershipsState: LoadState = .idle
    /// 追加・更新（POST/PATCH）の失敗。**一覧は消さず、この 1 行で伝える**（Q11 / AC-ID-10-M）。
    public var actionError: AppError?

    private let repository: (any IdentityRepository)?
    private let membershipRepository: (any MembershipRepository)?
    private let now: @Sendable () -> Date

    public init(
        repository: (any IdentityRepository)? = nil,
        membershipRepository: (any MembershipRepository)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.membershipRepository = membershipRepository
        self.now = now
    }

    public var today: Date { now() }

    // MARK: - 読み込み

    /// 名義と会員情報を取得する。失敗しても既読データは消さない（E-1 / Q11）。
    public func load() async {
        guard let repository, let membershipRepository else { return }
        identitiesState = .loading
        membershipsState = .loading
        do {
            identities = try await repository.list()
            identitiesState = .loaded
        } catch {
            identitiesState = .failed(Self.appError(from: error))
        }
        do {
            memberships = try await membershipRepository.list()
            membershipsState = .loaded
        } catch {
            membershipsState = .failed(Self.appError(from: error))
        }
    }

    /// ログアウト時に呼ぶ。
    ///
    /// **未ログインでもタブが見える**（Q5）ので、消さないと前のユーザーの名義がゲスト状態に残る。
    public func clear() {
        identities = []
        memberships = []
        identitiesState = .idle
        membershipsState = .idle
        actionError = nil
    }

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }

    // MARK: - 参照

    public func identity(for id: UUID) -> Identity? {
        identities.first { $0.id == id }
    }

    public func memberships(for identityID: UUID) -> [Membership] {
        memberships.filter { $0.identityID == identityID }
    }

    /// 直近の更新日（未設定は対象外）。
    public func nearestRenewal(for identityID: UUID) -> Date? {
        memberships(for: identityID).compactMap(\.renewalOn).min()
    }

    public func fanClubNames(for identityID: UUID) -> [String] {
        memberships(for: identityID).map(\.fanClubNameRaw)
    }

    public func expiringMembershipCount(within days: Int = 30) -> Int {
        let today = now()
        return memberships.compactMap(\.renewalOn).filter { renewalOn in
            let d = DateFormatting.daysUntil(from: today, to: renewalOn)
            return d >= 0 && d <= days
        }.count
    }

    /// 並び替え。当選数は `ApplicationStore.winCounts()` の結果を受け取る。
    public func sortedIdentities(by order: IdentitySortOrder, winCounts: [UUID: Int]) -> [Identity] {
        let today = now()
        let rows = identities.map { identity -> (Identity, Int?, Int) in
            let nearestDays = nearestRenewal(for: identity.id)
                .map { DateFormatting.daysUntil(from: today, to: $0) }
            return (identity, nearestDays, winCounts[identity.id] ?? 0)
        }

        switch order {
        case .renewalSoon:
            return rows.sorted { ($0.1 ?? Int.max) < ($1.1 ?? Int.max) }.map(\.0)
        case .mostWins:
            return rows.sorted { $0.2 > $1.2 }.map(\.0)
        case .joinedOldest:
            return rows.sorted { ($0.0.joinedOn ?? .distantFuture) < ($1.0.joinedOn ?? .distantFuture) }.map(\.0)
        }
    }

    // MARK: - 名義 / 会員情報の追加・更新（Repository 経由）
    //
    // UI へは**楽観的に**反映し、バックグラウンドでサーバーへ送る。
    // 失敗したら変更前の値に戻し、`actionError` に理由を残す（AC-ID-10-M:
    // 「API を止めた状態で名義を追加すると『オフラインです』が出て、UI の値が巻き戻る」）。

    @discardableResult
    public func addIdentity(
        displayName: String,
        relation: Relation,
        colorHex: String,
        joinedOn: Date?,
        note: String = ""
    ) -> Identity {
        let identity = Identity(
            displayName: displayName,
            relation: relation,
            colorHex: colorHex,
            joinedOn: joinedOn,
            note: note,
            sortOrder: identities.count,
            updatedAt: now()
        )
        identities.append(identity)
        persistCreate(identity)
        return identity
    }

    public func updateIdentityColor(_ id: UUID, colorHex: String) {
        guard let index = identities.firstIndex(where: { $0.id == id }) else { return }
        let previous = identities[index].colorHex
        guard previous != colorHex else { return }
        identities[index].colorHex = colorHex
        var patch = IdentityPatch()
        patch.colorHex = .set(colorHex)
        persistUpdate(id, patch: patch) { item in
            var item = item
            item.colorHex = previous
            return item
        }
    }

    public func updateIdentityNote(_ id: UUID, note: String) {
        guard let index = identities.firstIndex(where: { $0.id == id }) else { return }
        let previous = identities[index].note
        guard previous != note else { return }
        identities[index].note = note
        var patch = IdentityPatch()
        patch.note = .set(note)
        persistUpdate(id, patch: patch) { item in
            var item = item
            item.note = previous
            return item
        }
    }

    public func toggleHistoryVisible(_ id: UUID) {
        guard let index = identities.firstIndex(where: { $0.id == id }) else { return }
        let previous = identities[index].historyVisible
        identities[index].historyVisible = !previous
        var patch = IdentityPatch()
        patch.historyVisible = .set(!previous)
        persistUpdate(id, patch: patch) { item in
            var item = item
            item.historyVisible = previous
            return item
        }
    }

    @discardableResult
    public func addMembership(
        to identityID: UUID,
        fanClubNameRaw: String,
        memberNoLast4: String?,
        renewalOn: Date?,
        feeYen: Int?
    ) -> Membership {
        let membership = Membership(
            identityID: identityID,
            fanClubNameRaw: fanClubNameRaw,
            memberNoLast4: memberNoLast4,
            renewalOn: renewalOn,
            feeYen: feeYen
        )
        memberships.append(membership)
        persistMembershipCreate(membership)
        return membership
    }

    // MARK: - 内部: ネットワーク同期

    private func persistCreate(_ identity: Identity) {
        guard let repository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let created = try await repository.create(identity)
                self.replaceIdentity(identity.id, with: created)
                self.actionError = nil
            } catch {
                self.identities.removeAll { $0.id == identity.id }
                self.actionError = Self.appError(from: error)
            }
        }
    }

    private func persistUpdate(_ id: UUID, patch: IdentityPatch, revert: @escaping (Identity) -> Identity) {
        guard let repository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await repository.update(id: id, patch)
                self.replaceIdentity(id, with: updated)
                self.actionError = nil
            } catch {
                if let index = self.identities.firstIndex(where: { $0.id == id }) {
                    self.identities[index] = revert(self.identities[index])
                }
                self.actionError = Self.appError(from: error)
            }
        }
    }

    private func replaceIdentity(_ id: UUID, with identity: Identity) {
        guard let index = identities.firstIndex(where: { $0.id == id }) else { return }
        identities[index] = identity
    }

    private func persistMembershipCreate(_ membership: Membership) {
        guard let membershipRepository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let created = try await membershipRepository.create(membership)
                if let index = self.memberships.firstIndex(where: { $0.id == membership.id }) {
                    self.memberships[index] = created
                }
                self.actionError = nil
            } catch {
                self.memberships.removeAll { $0.id == membership.id }
                self.actionError = Self.appError(from: error)
            }
        }
    }
}
