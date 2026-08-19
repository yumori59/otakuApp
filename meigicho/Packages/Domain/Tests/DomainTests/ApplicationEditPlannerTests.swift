import XCTest
@testable import Domain

/// T1（`docs/plans/application-edit/plan.md`）: 編集フォームの差分計算の純粋関数テスト。
/// AC-AE-03〜06。
final class ApplicationEditPlannerTests: XCTestCase {
    private let repID = UUID()
    private let companionAID = UUID()
    private let companionBID = UUID()
    private let companionCID = UUID()
    private let tourID = UUID()
    private let eventID = UUID()

    private func makeCurrent(companions: [Companion] = []) -> ApplicationEntry {
        ApplicationEntry(
            id: UUID(),
            tourID: tourID,
            eventID: eventID,
            repIdentityID: repID,
            appliedOn: Date(timeIntervalSince1970: 1_700_000_000),
            resultOn: Date(timeIntervalSince1970: 1_700_100_000),
            status: .applied,
            seatRaw: "アリーナ8列15番",
            companions: companions,
            note: "既存メモ",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeTour() -> Tour {
        Tour(id: tourID, name: "STELLARIS ARENA TOUR 2026", artistNameRaw: "STELLARIS")
    }

    private func makeEvent() -> EventEntity {
        EventEntity(
            id: eventID,
            tourID: tourID,
            name: "STELLARIS ARENA TOUR 2026 -福岡公演-",
            venueNameRaw: "マリンメッセ福岡",
            eventDate: Date(timeIntervalSince1970: 1_700_200_000)
        )
    }

    /// current と全く同じ内容の input を作る（差分ゼロの基準ケース）。
    private func unchangedInput(companions: [CompanionInput] = []) -> ApplicationEditFormInput {
        let event = makeEvent()
        let tour = makeTour()
        return ApplicationEditFormInput(
            eventName: event.name,
            tourName: tour.name,
            artistNameRaw: tour.artistNameRaw,
            venueNameRaw: event.venueNameRaw,
            eventDate: event.eventDate,
            repIdentityID: repID,
            companions: companions,
            appliedOn: Date(timeIntervalSince1970: 1_700_000_000),
            resultOn: Date(timeIntervalSince1970: 1_700_100_000),
            status: .applied,
            seatRaw: "アリーナ8列15番",
            note: "既存メモ"
        )
    }

    // MARK: - AC-AE-05: 同行者無変更なら companions は .unchanged

    func testNoChangesProducesUnchangedCompanionsAndNoDrafts() {
        let companions = [
            Companion(id: companionAID, identityID: companionAID, displayName: "A", position: 0),
            Companion(id: companionBID, identityID: nil, displayName: "B（自由入力）", position: 1)
        ]
        let current = makeCurrent(companions: companions)
        let input = unchangedInput(companions: [
            CompanionInput(identityID: companionAID, displayName: "A"),
            CompanionInput(identityID: nil, displayName: "B（自由入力）")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.applicationPatch.companions, .unchanged)
        XCTAssertEqual(plan.applicationPatch, ApplicationPatch())
        XCTAssertNil(plan.tourDraft)
        XCTAssertNil(plan.eventDraft)
    }

    // MARK: - AC-AE-04: 表示名だけ変更 → id 不変

    func testDisplayNameOnlyChangeKeepsCompanionID() {
        let companions = [
            Companion(id: companionAID, identityID: nil, displayName: "旧名", position: 0)
        ]
        let current = makeCurrent(companions: companions)
        let input = unchangedInput(companions: [
            CompanionInput(identityID: nil, displayName: "新名")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        guard case .set(let updatedOpt) = plan.applicationPatch.companions, let updated = updatedOpt else {
            return XCTFail("companions が .set([...]) であるべき")
        }
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, companionAID, "id は新規発行されず保持される")
        XCTAssertEqual(updated[0].displayName, "新名")
        XCTAssertEqual(updated[0].position, 0)
    }

    // MARK: - AC-AE-03: 削除で残りが 0 起点連番になる

    func testRemovingMiddleCompanionRenumbersRemaining() {
        let companions = [
            Companion(id: companionAID, identityID: companionAID, displayName: "A", position: 0),
            Companion(id: companionBID, identityID: companionBID, displayName: "B", position: 1),
            Companion(id: companionCID, identityID: companionCID, displayName: "C", position: 2)
        ]
        let current = makeCurrent(companions: companions)
        // 真ん中（B）を削除
        let input = unchangedInput(companions: [
            CompanionInput(identityID: companionAID, displayName: "A"),
            CompanionInput(identityID: nil, displayName: ""),
            CompanionInput(identityID: companionCID, displayName: "C")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        guard case .set(let updatedOpt) = plan.applicationPatch.companions, let updated = updatedOpt else {
            return XCTFail("companions が .set([...]) であるべき")
        }
        XCTAssertEqual(updated.map(\.id), [companionAID, companionCID])
        XCTAssertEqual(updated.map(\.position), [0, 1])
    }

    // MARK: - AC-AE-06: 代表者と同一名義 / 重複名義 / 4 人目は弾かれる

    /// 追加フロー（`ApplicationFormView.saveCreate`）と同じく、代表者と同一名義が選ばれていても
    /// identityID を落として自由入力の表示名があれば同行者候補として残す（識別名義にはしない）
    func testCompanionSameAsRepFallsBackToFreeTextDisplayName() {
        let current = makeCurrent(companions: [])
        let input = unchangedInput(companions: [
            CompanionInput(identityID: repID, displayName: "代表者と同じ名義だが自由入力名あり")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        guard case .set(let updatedOpt) = plan.applicationPatch.companions, let updated = updatedOpt else {
            return XCTFail("companions が .set([...]) であるべき（identityID を落として displayName で残る）")
        }
        XCTAssertEqual(updated.count, 1)
        XCTAssertNil(updated[0].identityID, "代表者と同一名義は識別名義として使わない")
        XCTAssertEqual(updated[0].displayName, "代表者と同じ名義だが自由入力名あり")
    }

    /// 代表者と同一名義が選ばれていて、かつ自由入力名も無い（本当に何も入力していない）場合だけ捨てる
    func testCompanionSameAsRepWithoutDisplayNameIsDropped() {
        let current = makeCurrent(companions: [])
        let input = unchangedInput(companions: [
            CompanionInput(identityID: repID, displayName: "")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.applicationPatch.companions, .unchanged)
    }

    func testDuplicateCompanionIdentityIsDeduped() {
        let current = makeCurrent(companions: [])
        let input = unchangedInput(companions: [
            CompanionInput(identityID: companionAID, displayName: "A"),
            CompanionInput(identityID: companionAID, displayName: "A（重複）")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        guard case .set(let updatedOpt) = plan.applicationPatch.companions, let updated = updatedOpt else {
            return XCTFail("companions が .set([...]) であるべき")
        }
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].identityID, companionAID)
    }

    func testFourthCompanionIsDroppedByCap() {
        let current = makeCurrent(companions: [])
        let d = UUID()
        let input = unchangedInput(companions: [
            CompanionInput(identityID: companionAID, displayName: "A"),
            CompanionInput(identityID: companionBID, displayName: "B"),
            CompanionInput(identityID: companionCID, displayName: "C"),
            CompanionInput(identityID: d, displayName: "D")
        ])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        guard case .set(let updatedOpt) = plan.applicationPatch.companions, let updated = updatedOpt else {
            return XCTFail("companions が .set([...]) であるべき")
        }
        XCTAssertEqual(updated.count, 3, "同行者は最大3人（ApplicationStore.maxCompanions）")
        XCTAssertFalse(updated.contains { $0.identityID == d })
    }

    // MARK: - ApplicationPatch の他フィールド

    func testStatusAndSeatAndNoteChangesAreCaptured() {
        let current = makeCurrent(companions: [])
        var input = unchangedInput(companions: [])
        input.status = .won
        input.seatRaw = "アリーナ1列1番"
        input.note = "新しいメモ"

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.applicationPatch.status, .set(.won))
        XCTAssertEqual(plan.applicationPatch.seatRaw, .set("アリーナ1列1番"))
        XCTAssertEqual(plan.applicationPatch.note, .set("新しいメモ"))
        // 触っていないフィールドは unchanged のまま
        XCTAssertEqual(plan.applicationPatch.repIdentityID, .unchanged)
        XCTAssertEqual(plan.applicationPatch.repMembershipID, .unchanged)
    }

    func testRepIdentityChangeIsCaptured() {
        let current = makeCurrent(companions: [])
        let newRep = UUID()
        var input = unchangedInput(companions: [])
        input.repIdentityID = newRep

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.applicationPatch.repIdentityID, .set(newRep))
    }

    // MARK: - TourDraft / EventDraft

    func testTourNameChangeProducesFreshTourDraft() {
        let current = makeCurrent(companions: [])
        var input = unchangedInput(companions: [])
        input.tourName = "新ツアー名"

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertNotNil(plan.tourDraft)
        XCTAssertEqual(plan.tourDraft?.name, "新ツアー名")
        XCTAssertNotEqual(plan.tourDraft?.id, tourID, "付け替え候補として新規 id を持つ（find-or-create は下位層の責務）")
        XCTAssertNil(plan.eventDraft)
    }

    func testArtistOnlyChangeKeepsCurrentTourID() {
        let current = makeCurrent(companions: [])
        var input = unchangedInput(companions: [])
        input.artistNameRaw = "新アーティスト名"

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.tourDraft?.id, tourID, "ツアー名が同じなら現在の tour をその場で更新する")
        XCTAssertEqual(plan.tourDraft?.artistNameRaw, "新アーティスト名")
    }

    func testEventFieldChangeProducesEventDraftWithSameID() {
        let current = makeCurrent(companions: [])
        var input = unchangedInput(companions: [])
        input.venueNameRaw = "新会場"

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.eventDraft?.id, eventID, "公演は付け替えでなく現地更新")
        XCTAssertEqual(plan.eventDraft?.venueNameRaw, "新会場")
        XCTAssertNil(plan.tourDraft)
    }

    /// ツアー名を空欄にすると、追加フロー（`ApplicationFormView.trimmedTourName`）と同じく
    /// 公演名がツアー名として使われる
    func testEmptyTourNameFallsBackToEventName() {
        let current = makeCurrent(companions: [])
        var input = unchangedInput(companions: [])
        input.tourName = "   "

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertEqual(plan.tourDraft?.name, makeEvent().name, "空欄のツアー名は公演名にフォールバックする")
        XCTAssertNotEqual(plan.tourDraft?.id, tourID, "フォールバック後の名前は現在のツアー名と異なるので付け替え候補")
    }

    func testNoEventOrTourChangeProducesNilDrafts() {
        let current = makeCurrent(companions: [])
        let input = unchangedInput(companions: [])

        let plan = ApplicationEditPlanner.makePlan(
            current: current, currentTour: makeTour(), currentEvent: makeEvent(), input: input
        )

        XCTAssertNil(plan.tourDraft)
        XCTAssertNil(plan.eventDraft)
    }
}
