import Foundation

public extension Entitlement {
    /// Plus（`identityLimit == nil`）または枠内なら追加可。
    func canAddIdentity(currentCount: Int) -> Bool {
        guard let limit = identityLimit else { return true }
        return currentCount < limit
    }

    /// 同時に有効な共有リンクを新規発行できるか。
    func canCreateShareLink(activeLinkCount: Int) -> Bool {
        guard let limit = shareLimit else { return true }
        return activeLinkCount < limit
    }

    var isPlus: Bool { plan == .plus }

    /// `docs/07` §9.2: CustomerInfo（local）とサーバーミラーが食い違うとき、有効期限が長い方を採用。
    /// bonus 枠はサーバーのみが知るので、local を残す場合でも remote から取り込む。
    static func mergingPreferringLongerAccess(local: Entitlement?, remote: Entitlement) -> Entitlement {
        guard let local else { return remote }
        guard accessRank(local) > accessRank(remote) else { return remote }
        var kept = local
        kept.bonusIdentitySlots = remote.bonusIdentitySlots
        kept.bonusExpiresAt = remote.bonusExpiresAt
        return kept
    }

    /// Plus の強さ。free=0、期限なし Plus が最大。猶予中は expiresAt（なければ猶予窓の仮値）。
    static func accessRank(_ entitlement: Entitlement) -> TimeInterval {
        guard entitlement.plan == .plus else { return 0 }
        if let expiresAt = entitlement.expiresAt {
            return expiresAt.timeIntervalSince1970
        }
        if entitlement.inGracePeriod {
            return Date().timeIntervalSince1970 + 16 * 86_400
        }
        return .greatestFiniteMagnitude / 2
    }
}
