import XCTest
@testable import Domain

/// TE-1（`docs/plans/identity-edit-and-delete/plan.md`）: 名義編集フォームの差分計算の純粋関数テスト。
/// AC-IE-02〜06。
final class IdentityEditPlannerTests: XCTestCase {
    private let identityID = UUID()
    private let joinedOn = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCurrent(
        displayName: String = "鈴木 花子",
        relation: Relation = .friend,
        colorHex: String = "#FF00AA",
        joinedOn: Date? = nil,
        note: String = "既存メモ",
        historyVisible: Bool = true,
        sortOrder: Int = 3
    ) -> Identity {
        Identity(
            id: identityID,
            displayName: displayName,
            relation: relation,
            colorHex: colorHex,
            joinedOn: joinedOn,
            historyVisible: historyVisible,
            note: note,
            sortOrder: sortOrder
        )
    }

    /// current と全く同じ内容の input を作る（差分ゼロの基準ケース）。
    private func unchangedInput(current: Identity) -> IdentityEditFormInput {
        IdentityEditFormInput(
            displayName: current.displayName,
            relation: current.relation,
            joinedOn: current.joinedOn,
            colorHex: current.colorHex,
            note: current.note
        )
    }

    // MARK: - AC-IE-03: 全項目無変更なら patch == IdentityPatch()

    func testNoChangesProducesEmptyPatch() {
        let current = makeCurrent()
        let patch = IdentityEditPlanner.makePatch(current: current, input: unchangedInput(current: current))

        XCTAssertEqual(patch, IdentityPatch())
    }

    // MARK: - AC-IE-02: 表示名だけ変更 → displayName のみ .set、他は .unchanged

    func testDisplayNameOnlyChangeSetsOnlyDisplayName() {
        let current = makeCurrent()
        var input = unchangedInput(current: current)
        input.displayName = "  鈴木 花子2  "

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.displayName, .set("鈴木 花子2"))
        XCTAssertEqual(patch.relation, .unchanged)
        XCTAssertEqual(patch.colorHex, .unchanged)
        XCTAssertEqual(patch.joinedOn, .unchanged)
        XCTAssertEqual(patch.note, .unchanged)
        XCTAssertEqual(patch.historyVisible, .unchanged)
        XCTAssertEqual(patch.sortOrder, .unchanged)
    }

    // MARK: - AC-IE-04: joinedOn が未設定の名義を、日付に触れずに保存 → .unchanged

    func testUntouchedNilJoinedOnStaysUnchanged() {
        let current = makeCurrent(joinedOn: nil)
        let input = unchangedInput(current: current)

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.joinedOn, .unchanged)
    }

    // MARK: - AC-IE-05: 入会日を「未設定にする」 → .set(nil)（キー省略ではなく明示的な null）

    func testExplicitlyClearingJoinedOnSetsNil() {
        let current = makeCurrent(joinedOn: joinedOn)
        var input = unchangedInput(current: current)
        input.joinedOn = nil

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.joinedOn, .set(nil))
    }

    // MARK: - joinedOn を新しい日付へ変更 → .set(newDate)

    func testChangingJoinedOnSetsNewDate() {
        let current = makeCurrent(joinedOn: joinedOn)
        let newDate = joinedOn.addingTimeInterval(86_400)
        var input = unchangedInput(current: current)
        input.joinedOn = newDate

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.joinedOn, .set(newDate))
    }

    // MARK: - AC-IE-06: relation を操作していなければ .unchanged。未知 raw ("other" フォールバック) を書き潰さない

    func testUntouchedRelationStaysUnchangedEvenWhenFallenBackToOther() {
        // `Identity.relation` は DataStore 側の getter で未知 raw を既に `.other` へフォールバック済みの値
        // （`IdentityRecord.swift`）。View がその値をそのまま Picker の初期選択にする前提で、
        // 未操作なら input.relation == current.relation となり .unchanged になることを確認する。
        let current = makeCurrent(relation: .other)
        let input = unchangedInput(current: current)

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.relation, .unchanged)
    }

    func testChangingRelationSetsNewValue() {
        let current = makeCurrent(relation: .friend)
        var input = unchangedInput(current: current)
        input.relation = .family

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.relation, .set(.family))
    }

    // MARK: - colorHex / note の trim + 差分

    func testColorHexAndNoteChangeAreTrimmedAndSet() {
        let current = makeCurrent(colorHex: "#111111", note: "旧メモ")
        var input = unchangedInput(current: current)
        input.colorHex = "  #222222  "
        input.note = "  新メモ  "

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.colorHex, .set("#222222"))
        XCTAssertEqual(patch.note, .set("新メモ"))
    }

    // MARK: - historyVisible / sortOrder はフォームに項目が無いので常に .unchanged（FR-IE-3）

    func testHistoryVisibleAndSortOrderAreAlwaysUnchanged() {
        let current = makeCurrent(historyVisible: false, sortOrder: 5)
        var input = unchangedInput(current: current)
        input.displayName = "変更後"

        let patch = IdentityEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.historyVisible, .unchanged)
        XCTAssertEqual(patch.sortOrder, .unchanged)
    }
}
