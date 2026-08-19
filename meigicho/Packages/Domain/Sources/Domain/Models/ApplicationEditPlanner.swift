import Foundation
import Core

/// 編集フォームの同行者スロット 1 枠分の入力。
/// `identityID` が選ばれていれば名義の表示名、そうでなければ自由入力の氏名を `displayName` に持つ
/// （`AddApplicationView.swift` の `companionSelections` / `companionNames` に対応）。
public struct CompanionInput: Equatable, Sendable {
    public var identityID: UUID?
    public var displayName: String

    public init(identityID: UUID? = nil, displayName: String = "") {
        self.identityID = identityID
        self.displayName = displayName
    }

    var isEmpty: Bool {
        identityID == nil && displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 編集フォーム（`AddApplicationView.swift` と同じ 12 項目）の入力値。
/// `ApplicationEditPlanner` はこれと編集前の値（`ApplicationEntry` / `Tour` / `EventEntity`）から
/// 差分（`ApplicationPatch` / `TourDraft?` / `EventDraft?`）を計算する。
public struct ApplicationEditFormInput: Equatable, Sendable {
    public var eventName: String
    public var tourName: String
    public var artistNameRaw: String
    public var venueNameRaw: String
    public var eventDate: Date?
    public var repIdentityID: UUID
    /// 同行者スロット。既存同行者との対応は**インデックス（= `position`）**で取る（FR-AE-5）
    public var companions: [CompanionInput]
    public var appliedOn: Date?
    public var resultOn: Date?
    public var status: ApplicationStatus
    public var seatRaw: String
    public var note: String

    public init(
        eventName: String,
        tourName: String,
        artistNameRaw: String = "",
        venueNameRaw: String = "",
        eventDate: Date? = nil,
        repIdentityID: UUID,
        companions: [CompanionInput] = [],
        appliedOn: Date? = nil,
        resultOn: Date? = nil,
        status: ApplicationStatus,
        seatRaw: String = "",
        note: String = ""
    ) {
        self.eventName = eventName
        self.tourName = tourName
        self.artistNameRaw = artistNameRaw
        self.venueNameRaw = venueNameRaw
        self.eventDate = eventDate
        self.repIdentityID = repIdentityID
        self.companions = companions
        self.appliedOn = appliedOn
        self.resultOn = resultOn
        self.status = status
        self.seatRaw = seatRaw
        self.note = note
    }
}

/// `ApplicationEditPlanner.makePlan` の戻り値。
/// `tourDraft` / `eventDraft` は変更が無ければ `nil`（呼び出し側は sync push に含めない）。
public struct ApplicationEditPlan: Equatable, Sendable {
    public var applicationPatch: ApplicationPatch
    public var tourDraft: TourDraft?
    public var eventDraft: EventDraft?

    public init(applicationPatch: ApplicationPatch, tourDraft: TourDraft?, eventDraft: EventDraft?) {
        self.applicationPatch = applicationPatch
        self.tourDraft = tourDraft
        self.eventDraft = eventDraft
    }
}

/// 申込編集フォームの入力から差分パッチを組み立てる純粋関数群（T1・`docs/plans/application-edit/plan.md`）。
/// View / SwiftData には一切依存しない。
public enum ApplicationEditPlanner {
    /// 編集フォームの入力から `ApplicationPatch` / `TourDraft?` / `EventDraft?` を組み立てる。
    ///
    /// - Parameters:
    ///   - current: 編集前の申込（同行者を含む）
    ///   - currentTour: 編集前の `event.tourID` が指すツアー
    ///   - currentEvent: 編集前の公演
    ///   - input: フォームの現在の入力値
    public static func makePlan(
        current: ApplicationEntry,
        currentTour: Tour,
        currentEvent: EventEntity,
        input: ApplicationEditFormInput
    ) -> ApplicationEditPlan {
        var patch = ApplicationPatch()

        if input.repIdentityID != current.repIdentityID {
            patch.repIdentityID = .set(input.repIdentityID)
        }
        if input.appliedOn != current.appliedOn {
            patch.appliedOn = .set(input.appliedOn)
        }
        if input.resultOn != current.resultOn {
            patch.resultOn = .set(input.resultOn)
        }
        if input.status != current.status {
            patch.status = .set(input.status)
        }
        let seat = input.seatRaw.trimmingCharacters(in: .whitespaces)
        if seat != current.seatRaw {
            patch.seatRaw = .set(seat)
        }
        let note = input.note.trimmingCharacters(in: .whitespaces)
        if note != current.note {
            patch.note = .set(note)
        }
        // FR-AE-7 / C-4: 会員情報連携はスコープ外。編集でも常に送らない
        patch.repMembershipID = .unchanged
        patch.roundName = .unchanged
        patch.ticketCount = .unchanged
        patch.priceYen = .unchanged

        patch.companions = makeCompanionsPatch(
            current: current.companions,
            repIdentityID: input.repIdentityID,
            slots: input.companions
        )

        return ApplicationEditPlan(
            applicationPatch: patch,
            tourDraft: makeTourDraft(currentTour: currentTour, input: input),
            eventDraft: makeEventDraft(currentEvent: currentEvent, input: input)
        )
    }

    /// FR-AE-4/5/6: 同行者の差分を計算する。
    /// 既存同行者との対応はスロットの**インデックス**（＝ `position`）で取り、`id` を保持する（AC-AE-04）。
    /// 重複除去・上限・`position` 再採番は `CompanionNormalizer`（`ApplicationStore.normalizedCompanions` と共通）を再利用する（重複実装しない）。
    public static func makeCompanionsPatch(
        current: [Companion],
        repIdentityID: UUID,
        slots: [CompanionInput]
    ) -> Patchable<[Companion]> {
        let normalizedCurrent = CompanionNormalizer.normalize(current)
        let sortedCurrent = current.sorted { $0.position < $1.position }

        var candidates: [Companion] = []
        for (index, slot) in slots.enumerated() {
            guard !slot.isEmpty else { continue }
            // AC-AE-06: 代表者と同一名義は同行者の**識別名義**にはできない。
            // 追加フロー（`ApplicationFormView.saveCreate`）と同じく、identityID を落として
            // 自由入力の表示名があれば同行者候補として残す（表示名も空なら本当に捨てる）
            let identityID = slot.identityID == repIdentityID ? nil : slot.identityID
            let name = slot.displayName.trimmingCharacters(in: .whitespaces)
            guard identityID != nil || !name.isEmpty else { continue }
            let existingID = index < sortedCurrent.count ? sortedCurrent[index].id : nil
            candidates.append(
                Companion(
                    id: existingID ?? UUIDv7.generate(),
                    identityID: identityID,
                    displayName: name,
                    position: candidates.count
                )
            )
        }

        let normalized = CompanionNormalizer.normalize(candidates)
        return normalized == normalizedCurrent ? .unchanged : .set(normalized)
    }

    /// FR-AE-8/9: ツアー名またはアーティスト名が変わっていれば `TourDraft` を返す。
    /// ツアー名を空欄にした場合は**公演名をツアー名として使う**（追加フロー `ApplicationFormView.trimmedTourName`
    /// と同じフォールバック。UI ヒント「空欄の場合は公演名がそのままツアー名として使われます。」と挙動を揃える）。
    /// ツアー名が変わる場合は付け替え（find-or-create）の元データとして**新規 UUID**を、
    /// ツアー名が変わらない場合（アーティスト名のみ変更）は**同じツアーの現地更新**として現在の `id` を使う。
    static func makeTourDraft(currentTour: Tour, input: ApplicationEditFormInput) -> TourDraft? {
        let trimmedTourName = input.tourName.trimmingCharacters(in: .whitespaces)
        let name = trimmedTourName.isEmpty
            ? input.eventName.trimmingCharacters(in: .whitespaces)
            : trimmedTourName
        let artistNameRaw = input.artistNameRaw.trimmingCharacters(in: .whitespaces)
        guard name != currentTour.name || artistNameRaw != currentTour.artistNameRaw else { return nil }
        let id = name == currentTour.name ? currentTour.id : UUIDv7.generate()
        return TourDraft(id: id, name: name, artistNameRaw: artistNameRaw)
    }

    /// FR-AE-7: 公演名 / 会場 / 公演日が変わっていれば `EventDraft` を返す。
    /// 公演は付け替えではなく現地更新なので、`id` は常に編集前の `currentEvent.id` を使う。
    static func makeEventDraft(currentEvent: EventEntity, input: ApplicationEditFormInput) -> EventDraft? {
        let name = input.eventName.trimmingCharacters(in: .whitespaces)
        let venueNameRaw = input.venueNameRaw.trimmingCharacters(in: .whitespaces)
        guard name != currentEvent.name
            || venueNameRaw != currentEvent.venueNameRaw
            || input.eventDate != currentEvent.eventDate
        else { return nil }
        return EventDraft(
            id: currentEvent.id,
            name: name,
            venueNameRaw: venueNameRaw,
            eventDate: input.eventDate,
            startsAt: currentEvent.startsAt
        )
    }
}
