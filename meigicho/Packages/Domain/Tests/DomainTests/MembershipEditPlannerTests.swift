import XCTest
@testable import Domain

/// TE-1（`docs/plans/identity-edit-and-delete/plan.md`）: 会員情報編集フォームの差分計算の純粋関数テスト。
/// AC-IE-11〜13 相当（Domain 側の純粋関数分。DataStore 側の反映確認は TE-2）。
final class MembershipEditPlannerTests: XCTestCase {
    private let membershipID = UUID()
    private let identityID = UUID()
    private let renewalOn = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCurrent(
        fanClubNameRaw: String = "STELLARIS OFFICIAL FAN CLUB",
        memberNoLast4: String? = "4821",
        rank: String? = "プラチナ",
        renewalOn: Date? = nil,
        feeYen: Int? = 4000,
        autoRenew: Bool = true,
        note: String = "既存メモ"
    ) -> Membership {
        Membership(
            id: membershipID,
            identityID: identityID,
            fanClubNameRaw: fanClubNameRaw,
            memberNoLast4: memberNoLast4,
            rank: rank,
            renewalOn: renewalOn,
            feeYen: feeYen,
            autoRenew: autoRenew,
            note: note
        )
    }

    /// current と全く同じ内容の input を作る（差分ゼロの基準ケース）。
    private func unchangedInput(current: Membership) -> MembershipEditFormInput {
        MembershipEditFormInput(
            fanClubNameRaw: current.fanClubNameRaw,
            memberNoLast4Raw: current.memberNoLast4 ?? "",
            renewalOn: current.renewalOn,
            feeYen: current.feeYen
        )
    }

    // MARK: - 全項目無変更なら patch == MembershipPatch()

    func testNoChangesProducesEmptyPatch() {
        let current = makeCurrent()
        let patch = MembershipEditPlanner.makePatch(current: current, input: unchangedInput(current: current))

        XCTAssertEqual(patch, MembershipPatch())
    }

    // MARK: - AC-IE-11: FC 名だけ変更 → rank / autoRenew / note は保持（= .unchanged）

    func testFanClubNameOnlyChangeKeepsUnrelatedFieldsUnchanged() {
        let current = makeCurrent()
        var input = unchangedInput(current: current)
        input.fanClubNameRaw = "  新FC名  "

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.fanClubNameRaw, .set("新FC名"))
        XCTAssertEqual(patch.identityID, .unchanged)
        XCTAssertEqual(patch.rank, .unchanged)
        XCTAssertEqual(patch.autoRenew, .unchanged)
        XCTAssertEqual(patch.note, .unchanged)
        XCTAssertEqual(patch.memberNoLast4, .unchanged)
        XCTAssertEqual(patch.renewalOn, .unchanged)
        XCTAssertEqual(patch.feeYen, .unchanged)
    }

    // MARK: - AC-IE-12: 更新日を「未設定」へ切り替え → .set(nil)

    func testExplicitlyClearingRenewalOnSetsNil() {
        let current = makeCurrent(renewalOn: renewalOn)
        var input = unchangedInput(current: current)
        input.renewalOn = nil

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.renewalOn, .set(nil))
    }

    // MARK: - 更新日が未設定のまま触れなければ .unchanged

    func testUntouchedNilRenewalOnStaysUnchanged() {
        let current = makeCurrent(renewalOn: nil)
        let input = unchangedInput(current: current)

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.renewalOn, .unchanged)
    }

    func testChangingRenewalOnSetsNewDate() {
        let current = makeCurrent(renewalOn: renewalOn)
        let newDate = renewalOn.addingTimeInterval(86_400)
        var input = unchangedInput(current: current)
        input.renewalOn = newDate

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.renewalOn, .set(newDate))
    }

    // MARK: - AC-IE-23 / C5: 会員番号下 4 桁は trim。空にすると .set(nil)

    func testMemberNoLast4IsTrimmedAndEmptyBecomesNil() {
        let current = makeCurrent(memberNoLast4: "4821")
        var input = unchangedInput(current: current)
        input.memberNoLast4Raw = "  "

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.memberNoLast4, .set(nil))
    }

    func testMemberNoLast4TrimmedValueEqualToCurrentStaysUnchanged() {
        let current = makeCurrent(memberNoLast4: "4821")
        var input = unchangedInput(current: current)
        input.memberNoLast4Raw = "  4821  "

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.memberNoLast4, .unchanged)
    }

    // MARK: - feeYen を未設定へ変更 → .set(nil)

    func testExplicitlyClearingFeeYenSetsNil() {
        let current = makeCurrent(feeYen: 4000)
        var input = unchangedInput(current: current)
        input.feeYen = nil

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.feeYen, .set(nil))
    }

    func testChangingFeeYenSetsNewValue() {
        let current = makeCurrent(feeYen: 4000)
        var input = unchangedInput(current: current)
        input.feeYen = 5000

        let patch = MembershipEditPlanner.makePatch(current: current, input: input)

        XCTAssertEqual(patch.feeYen, .set(5000))
    }
}
