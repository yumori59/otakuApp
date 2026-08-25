import Foundation

/// 会員情報編集フォーム（追加フォームと同一 4 項目・`AddMembershipView.swift`）の入力値。
/// `MembershipEditPlanner` はこれと編集前の `Membership` から差分（`MembershipPatch`）を計算する。
public struct MembershipEditFormInput: Equatable, Sendable {
    public var fanClubNameRaw: String
    /// 会員番号の生入力（全桁）。前後空白を trim し、空なら `nil` として扱う（FR-IE-23）
    public var memberNoRaw: String
    /// `nil` = 未設定。View は開いたときに現在値（`nil` も含む）を代入する
    public var renewalOn: Date?
    public var feeYen: Int?

    public init(
        fanClubNameRaw: String,
        memberNoRaw: String = "",
        renewalOn: Date? = nil,
        feeYen: Int? = nil
    ) {
        self.fanClubNameRaw = fanClubNameRaw
        self.memberNoRaw = memberNoRaw
        self.renewalOn = renewalOn
        self.feeYen = feeYen
    }
}

/// 会員情報編集フォームの入力から差分パッチを組み立てる純粋関数群
/// （TE-1・`docs/plans/identity-edit-and-delete/plan.md` D-3）。View / SwiftData には一切依存しない。
public enum MembershipEditPlanner {
    /// 編集フォームの入力から `MembershipPatch` を組み立てる。
    ///
    /// - 現在値と同じフィールドは `.unchanged`（キーごと送らない）
    /// - `renewalOn` / `memberNo` / `feeYen` を明示的に未設定へ変えた場合のみ `.set(nil)`（AC-IE-12）
    /// - `identityID` / `rank` / `autoRenew` / `note` はフォームに項目が無いため常に `.unchanged`
    ///   （FR-IE-19: 消えてはいけない）
    public static func makePatch(current: Membership, input: MembershipEditFormInput) -> MembershipPatch {
        var patch = MembershipPatch()

        let fcName = input.fanClubNameRaw.trimmingCharacters(in: .whitespaces)
        if fcName != current.fanClubNameRaw {
            patch.fanClubNameRaw = .set(fcName)
        }

        let trimmedMemberNo = input.memberNoRaw.trimmingCharacters(in: .whitespaces)
        let memberNo = trimmedMemberNo.isEmpty ? nil : trimmedMemberNo
        if memberNo != current.memberNo {
            patch.memberNo = .set(memberNo)
        }

        if input.renewalOn != current.renewalOn {
            patch.renewalOn = .set(input.renewalOn)
        }

        if input.feeYen != current.feeYen {
            patch.feeYen = .set(input.feeYen)
        }

        patch.identityID = .unchanged
        patch.rank = .unchanged
        patch.autoRenew = .unchanged
        patch.note = .unchanged

        return patch
    }
}
