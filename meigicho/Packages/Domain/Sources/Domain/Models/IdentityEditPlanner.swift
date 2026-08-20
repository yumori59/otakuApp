import Foundation

/// 名義編集フォーム（追加フォームと同一 5 項目・`AddIdentityView.swift`）の入力値。
/// `IdentityEditPlanner` はこれと編集前の `Identity` から差分（`IdentityPatch`）を計算する。
public struct IdentityEditFormInput: Equatable, Sendable {
    public var displayName: String
    public var relation: Relation
    /// `nil` = 未設定。View は開いたときに現在値（`nil` も含む）を代入し、
    /// ユーザーが「未設定にする」を選んだときだけ `nil` に変える（`docs/plans/identity-edit-and-delete/plan.md` D-8）。
    public var joinedOn: Date?
    public var colorHex: String
    public var note: String

    public init(
        displayName: String,
        relation: Relation,
        joinedOn: Date? = nil,
        colorHex: String,
        note: String = ""
    ) {
        self.displayName = displayName
        self.relation = relation
        self.joinedOn = joinedOn
        self.colorHex = colorHex
        self.note = note
    }
}

/// 名義編集フォームの入力から差分パッチを組み立てる純粋関数群
/// （TE-1・`docs/plans/identity-edit-and-delete/plan.md` D-3）。View / SwiftData には一切依存しない。
public enum IdentityEditPlanner {
    /// 編集フォームの入力から `IdentityPatch` を組み立てる。
    ///
    /// - 現在値と同じフィールドは `.unchanged`（キーごと送らない）
    /// - `joinedOn` を明示的に未設定へ変えた場合のみ `.set(nil)`（AC-IE-05）
    /// - `relation` を操作していなければ `.unchanged`。`Identity.relation` は既に
    ///   未知 raw 値のフォールバック（`.other`）が適用済みの値なので、View が現在値を
    ///   そのまま Picker の初期選択にしていれば、未操作時は自動的に一致し `.unchanged` になる（AC-IE-06 / R-2）
    /// - `historyVisible` / `sortOrder` はフォームに項目が無いため常に `.unchanged`（FR-IE-3）
    public static func makePatch(current: Identity, input: IdentityEditFormInput) -> IdentityPatch {
        var patch = IdentityPatch()

        let displayName = input.displayName.trimmingCharacters(in: .whitespaces)
        if displayName != current.displayName {
            patch.displayName = .set(displayName)
        }
        if input.relation != current.relation {
            patch.relation = .set(input.relation)
        }
        let colorHex = input.colorHex.trimmingCharacters(in: .whitespaces)
        if colorHex != current.colorHex {
            patch.colorHex = .set(colorHex)
        }
        if input.joinedOn != current.joinedOn {
            patch.joinedOn = .set(input.joinedOn)
        }
        let note = input.note.trimmingCharacters(in: .whitespaces)
        if note != current.note {
            patch.note = .set(note)
        }
        patch.historyVisible = .unchanged
        patch.sortOrder = .unchanged

        return patch
    }
}
