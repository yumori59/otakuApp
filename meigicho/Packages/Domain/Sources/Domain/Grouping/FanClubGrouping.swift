import Foundation
import Core

/// FC / アーティスト名（`Membership.fanClubNameRaw`）をキーに名義一覧を束ねるための型と純粋関数群。
/// BE・DB 変更なし。`docs/plans/identity-grouping/` を正とする。
public struct FanClubGroup: Identifiable, Equatable, Sendable {
    /// 正規化キー。FC未登録グループは "" 固定
    public let id: String
    /// 画面に出す名前。原文 or "FC未登録"
    public let displayName: String
    public let rows: [Row]
    /// グループ内の最小 renewalOn（並び順の基準。nil のみなら nil）
    public let nearestRenewalOn: Date?
    public var isUnregistered: Bool { id.isEmpty }

    public struct Row: Identifiable, Equatable, Sendable {
        public let identity: Identity
        public let membership: Membership?

        public var id: String { "\(identity.id.uuidString)#\(membership?.id.uuidString ?? "none")" }
    }

    public init(
        id: String,
        displayName: String,
        rows: [Row],
        nearestRenewalOn: Date?
    ) {
        self.id = id
        self.displayName = displayName
        self.rows = rows
        self.nearestRenewalOn = nearestRenewalOn
    }
}

public enum FanClubGrouping {
    /// FC 名の同一判定キー（FR-IG-3 / AC-IG-04,05）。
    /// トリム + 連続空白圧縮 + 全角/半角 + 大小のみ畳む。濁点・かなカナは畳まない。
    public static func fanClubGroupKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
        let spaceNormalized = folded
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return spaceNormalized
    }

    /// 正規化後に空なら FC未登録扱い（E-3）。
    public static func isUnregisteredKey(_ raw: String) -> Bool {
        fanClubGroupKey(raw).isEmpty
    }

    /// 同一名義×同一FCの重複会員情報を 1 行に畳む（FR-IG-10）。
    /// 採用するのは `renewalOn` が最も近い方（nil は最劣後）。
    public static func pickPreferredMembership(_ memberships: [Membership], today: Date) -> Membership? {
        memberships.min { lhs, rhs in
            let lDays = lhs.renewalOn.map { DateFormatting.daysUntil(from: today, to: $0) }
            let rDays = rhs.renewalOn.map { DateFormatting.daysUntil(from: today, to: $0) }
            switch (lDays, rDays) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    /// グループ内の行をソートする（FR-IG-7〜9）。
    public static func sortRows(
        _ rows: [FanClubGroup.Row],
        by order: IdentitySortOrder,
        winCounts: [UUID: Int],
        today: Date
    ) -> [FanClubGroup.Row] {
        switch order {
        case .renewalSoon:
            return rows.sorted { lhs, rhs in
                let lDays = lhs.membership?.renewalOn.map { DateFormatting.daysUntil(from: today, to: $0) }
                let rDays = rhs.membership?.renewalOn.map { DateFormatting.daysUntil(from: today, to: $0) }
                switch (lDays, rDays) {
                case (let l?, let r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return lhs.identity.displayName.localizedStandardCompare(rhs.identity.displayName) == .orderedAscending
                }
            }
        case .mostWins:
            return rows.sorted { lhs, rhs in
                let lw = winCounts[lhs.identity.id] ?? 0
                let rw = winCounts[rhs.identity.id] ?? 0
                if lw != rw { return lw > rw }
                return lhs.identity.displayName.localizedStandardCompare(rhs.identity.displayName) == .orderedAscending
            }
        case .joinedOldest:
            return rows.sorted { lhs, rhs in
                let lJoined = lhs.identity.joinedOn ?? .distantFuture
                let rJoined = rhs.identity.joinedOn ?? .distantFuture
                if lJoined != rJoined { return lJoined < rJoined }
                return lhs.identity.displayName.localizedStandardCompare(rhs.identity.displayName) == .orderedAscending
            }
        }
    }

    /// グループの並び順（FR-IG-6 / AC-IG-06,07）。
    public static func sortGroups(_ groups: [FanClubGroup]) -> [FanClubGroup] {
        let registered = groups.filter { !$0.isUnregistered }
        let unregistered = groups.filter(\.isUnregistered)

        let sortedRegistered = registered.sorted { lhs, rhs in
            switch (lhs.nearestRenewalOn, rhs.nearestRenewalOn) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }

        return sortedRegistered + unregistered
    }
}

extension IdentityStore {
    /// 名義一覧を FC 名でグルーピングする（FR-IG-1〜11）。
    public func groupedByFanClub(
        sortedBy order: IdentitySortOrder,
        winCounts: [UUID: Int]
    ) -> [FanClubGroup] {
        let today = self.today
        let identityByID = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0) })

        struct Bucket {
            var displayName: String?
            var rows: [FanClubGroup.Row] = []
        }

        var buckets: [String: Bucket] = [:]

        for membership in memberships {
            guard identityByID[membership.identityID] != nil else { continue }
            let key = FanClubGrouping.fanClubGroupKey(membership.fanClubNameRaw)
            guard !key.isEmpty else { continue }
            if buckets[key] == nil {
                buckets[key] = Bucket(displayName: membership.fanClubNameRaw)
            }
            buckets[key]?.rows.append(
                FanClubGroup.Row(identity: identityByID[membership.identityID]!, membership: membership)
            )
        }

        // 同一名義×同一FCの重複会員情報を 1 行に畳む
        for key in buckets.keys {
            guard var bucket = buckets[key] else { continue }
            var byIdentity: [UUID: [Membership]] = [:]
            for row in bucket.rows {
                guard let membership = row.membership else { continue }
                byIdentity[membership.identityID, default: []].append(membership)
            }
            bucket.rows = byIdentity.compactMap { identityID, memberships -> FanClubGroup.Row? in
                guard let identity = identityByID[identityID] else { return nil }
                let preferred = FanClubGrouping.pickPreferredMembership(memberships, today: today)
                return FanClubGroup.Row(identity: identity, membership: preferred)
            }
            buckets[key] = bucket
        }

        var groups: [FanClubGroup] = buckets.map { key, bucket in
            let sortedRows = FanClubGrouping.sortRows(
                bucket.rows,
                by: order,
                winCounts: winCounts,
                today: today
            )
            let nearest = sortedRows.compactMap(\.membership?.renewalOn).min()
            return FanClubGroup(
                id: key,
                displayName: bucket.displayName ?? key,
                rows: sortedRows,
                nearestRenewalOn: nearest
            )
        }

        // 会員情報を 1 件も持たない名義 → FC未登録
        let identitiesWithMembership = Set(memberships.map(\.identityID))
        let unregisteredRows = identities
            .filter { !identitiesWithMembership.contains($0.id) }
            .map { FanClubGroup.Row(identity: $0, membership: nil) }
        if !unregisteredRows.isEmpty {
            let sortedUnregistered = FanClubGrouping.sortRows(
                unregisteredRows,
                by: order,
                winCounts: winCounts,
                today: today
            )
            groups.append(
                FanClubGroup(
                    id: "",
                    displayName: "FC未登録",
                    rows: sortedUnregistered,
                    nearestRenewalOn: nil
                )
            )
        }

        return FanClubGrouping.sortGroups(groups)
    }
}
