import XCTest
import Core
import Domain
@testable import Network

/// `contract-mapping.md` §4.5 / §4.6 の DTO 契約。
/// **BE がキーを改名したらここで落ちる**（IOS-2 の防波堤）。
final class ApplicationDTOTests: XCTestCase {
    private let identityA = UUID(uuidString: "018f3c2a-aaaa-7c90-9d2a-000000000001")!
    private let identityB = UUID(uuidString: "018f3c2a-aaaa-7c90-9d2a-000000000002")!

    // MARK: - デコード

    private static let applicationJSON = Data("""
    {
      "id": "018f3c2a-cccc-7c90-9d2a-000000000001",
      "tour_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
      "event_id": "018f3c2a-eeee-7c90-9d2a-000000000001",
      "rep_identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
      "rep_membership_id": null,
      "round_name": "FC1次",
      "applied_on": "2026-07-01",
      "result_on": "2026-07-20",
      "status": "applied",
      "seat_raw": null,
      "ticket_count": 2,
      "price_yen": 16000,
      "note": null,
      "companions": [
        { "id": "018f3c2a-ffff-7c90-9d2a-000000000002", "identity_id": null, "display_name": "友人", "position": 1 },
        { "id": "018f3c2a-ffff-7c90-9d2a-000000000001", "identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000002", "display_name": "妹", "position": 0 }
      ],
      "created_at": "2026-07-31T12:05:00.000Z",
      "updated_at": "2026-07-31T12:05:00.000Z",
      "deleted_at": null
    }
    """.utf8)

    func testApplicationResponseDecodesContractKeys() throws {
        let response = try JSONDecoder().decode(ApplicationResponse.self, from: Self.applicationJSON)
        let entry = try response.toDomain()

        XCTAssertEqual(entry.roundName, "FC1次")
        XCTAssertEqual(entry.status, .applied)
        XCTAssertEqual(entry.ticketCount, 2)
        XCTAssertEqual(entry.priceYen, 16000)
        // null は空文字で受ける（Domain 側は非 Optional）
        XCTAssertEqual(entry.seatRaw, "")
        XCTAssertEqual(entry.note, "")
        XCTAssertNil(entry.repMembershipID)
        // date-only は JST 00:00
        XCTAssertEqual(entry.appliedOn, jst(2026, 7, 1))
        XCTAssertEqual(entry.resultOn, jst(2026, 7, 20))
        // companions は position 昇順
        XCTAssertEqual(entry.companions.map(\.position), [0, 1])
        XCTAssertEqual(entry.companions.map(\.displayName), ["妹", "友人"])
        XCTAssertEqual(entry.companions[0].identityID, identityB)
        XCTAssertNil(entry.companions[1].identityID)
    }

    /// 未知の status は `.applied` にフォールバックするが、**デコード自体は失敗させない**（E-12）
    func testUnknownStatusFallsBackWithoutFailingDecode() throws {
        let json = Data(String(decoding: Self.applicationJSON, as: UTF8.self)
            .replacingOccurrences(of: "\"status\": \"applied\"", with: "\"status\": \"waitlisted\"").utf8)
        let entry = try JSONDecoder().decode(ApplicationResponse.self, from: json).toDomain()
        XCTAssertEqual(entry.status, .applied)
    }

    /// 非 null なのに解釈できない日付は黙って nil にしない
    func testInvalidDateOnlyThrows() throws {
        let json = Data(String(decoding: Self.applicationJSON, as: UTF8.self)
            .replacingOccurrences(of: "\"applied_on\": \"2026-07-01\"", with: "\"applied_on\": \"2026/07/01\"").utf8)
        let response = try JSONDecoder().decode(ApplicationResponse.self, from: json)
        XCTAssertThrowsError(try response.toDomain())
    }

    func testApplicationPageDecodesCursorAsOpaqueString() throws {
        let json = Data("""
        { "items": [], "next_cursor": "2026-07-31T12:05:00.000Z|018f3c2a-cccc-7c90-9d2a-000000000001", "has_more": true }
        """.utf8)
        let page = try JSONDecoder().decode(ApplicationPageResponse.self, from: json).toDomain()
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "2026-07-31T12:05:00.000Z|018f3c2a-cccc-7c90-9d2a-000000000001")
    }

    func testTourAndEventResponsesDecodeContractKeys() throws {
        let tourJSON = Data("""
        {
          "id": "018f3c2a-dddd-7c90-9d2a-000000000001",
          "name": "STELLARIS LIVE TOUR 2026",
          "artist_name_raw": null,
          "created_at": "2026-08-01T00:00:00.000Z",
          "updated_at": "2026-08-01T00:00:00.000Z",
          "deleted_at": null
        }
        """.utf8)
        let tour = try JSONDecoder().decode(TourResponse.self, from: tourJSON).toDomain()
        XCTAssertEqual(tour.name, "STELLARIS LIVE TOUR 2026")
        XCTAssertEqual(tour.artistNameRaw, "", "null は空文字で受ける")

        let eventJSON = Data("""
        {
          "id": "018f3c2a-eeee-7c90-9d2a-000000000001",
          "tour_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
          "name": "大阪公演 Day1",
          "venue_name_raw": "大阪城ホール",
          "event_date": null,
          "starts_at": "2026-08-20T11:00:00Z",
          "created_at": "2026-08-01T00:00:00.000Z",
          "updated_at": "2026-08-01T00:00:00.000Z",
          "deleted_at": null
        }
        """.utf8)
        let event = try JSONDecoder().decode(EventResponse.self, from: eventJSON).toDomain()
        XCTAssertEqual(event.venueNameRaw, "大阪城ホール")
        XCTAssertNil(event.eventDate, "event_date は null がありうる（E-8）")
        // フラクショナル秒なしの datetime も解釈できる
        XCTAssertNotNil(event.startsAt)
    }

    // MARK: - エンコード（AC-AP-02-T / AC-AP-03-T / AC-AP-12）

    private func encodedCreateBody(_ draft: ApplicationDraft) throws -> [String: Any] {
        let data = try JSONEncoder().encode(CreateApplicationRequest(draft: draft))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCreateRequestSendsCompanionIDsAndZeroBasedPositions() throws {
        let companionA = Companion(id: UUID(), identityID: identityA, displayName: "妹", position: 3)
        let companionB = Companion(id: UUID(), identityID: nil, displayName: "友人", position: 7)
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR", artistNameRaw: "ARTIST"),
            event: EventDraft(name: "公演", venueNameRaw: "会場", eventDate: jst(2026, 8, 20)),
            repIdentityID: identityB,
            companions: [companionA, companionB]
        )

        let body = try encodedCreateBody(draft)
        let companions = try XCTUnwrap(body["companions"] as? [[String: Any]])
        XCTAssertEqual(companions.count, 2)
        XCTAssertEqual(companions.map { $0["position"] as? Int }, [0, 1])
        XCTAssertEqual(companions.compactMap { $0["id"] as? String }.count, 2, "id は必須")
        XCTAssertEqual(companions[0]["display_name"] as? String, "妹")

        // tour / event は複合 POST の中でしか作れない（C3）
        let tour = try XCTUnwrap(body["tour"] as? [String: Any])
        XCTAssertEqual(tour["name"] as? String, "TOUR")
        XCTAssertEqual(tour["artist_name_raw"] as? String, "ARTIST")
        let event = try XCTUnwrap(body["event"] as? [String: Any])
        XCTAssertEqual(event["event_date"] as? String, "2026-08-20", "date-only は JST の YYYY-MM-DD")
        XCTAssertNil(event["starts_at"], "未指定の starts_at はキーごと送らない")
    }

    func testCreateRequestDropsDuplicatedCompanionIdentityIDs() throws {
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR"),
            event: EventDraft(name: "公演"),
            repIdentityID: identityB,
            companions: [
                Companion(id: UUID(), identityID: identityA, displayName: "妹", position: 0),
                Companion(id: UUID(), identityID: identityA, displayName: "妹（重複）", position: 1),
                Companion(id: UUID(), identityID: nil, displayName: "友人", position: 2),
            ]
        )
        let companions = try XCTUnwrap(try encodedCreateBody(draft)["companions"] as? [[String: Any]])
        XCTAssertEqual(companions.count, 2)
        XCTAssertEqual(companions.map { $0["display_name"] as? String }, ["妹", "友人"])
    }

    func testCreateRequestCapsCompanionsAtThree() throws {
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR"),
            event: EventDraft(name: "公演"),
            repIdentityID: identityB,
            companions: (0..<5).map { Companion(id: UUID(), identityID: nil, displayName: "同行\($0)", position: $0) }
        )
        let companions = try XCTUnwrap(try encodedCreateBody(draft)["companions"] as? [[String: Any]])
        XCTAssertEqual(companions.count, 3)
    }

    /// AC-AP-12: `rep_membership_id` は常に null（値を入れる経路が無い）
    func testCreateRequestAlwaysSendsNullRepMembershipID() throws {
        var draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR"),
            event: EventDraft(name: "公演"),
            repIdentityID: identityB
        )
        draft.repMembershipID = UUID()
        let body = try encodedCreateBody(draft)
        XCTAssertTrue(body.keys.contains("rep_membership_id"))
        XCTAssertTrue(body["rep_membership_id"] is NSNull, "常に null を送る（FR-AP-7）")
    }

    func testCreateRequestOmitsEmptyOptionalStrings() throws {
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR", artistNameRaw: ""),
            event: EventDraft(name: "公演", venueNameRaw: ""),
            repIdentityID: identityB,
            seatRaw: "",
            note: ""
        )
        let body = try encodedCreateBody(draft)
        XCTAssertNil(body["seat_raw"])
        XCTAssertNil(body["note"])
        XCTAssertNil(body["round_name"])
        // Optional は synthesized encode が `encodeIfPresent` を使うのでキーごと省略される
        let tour = try XCTUnwrap(body["tour"] as? [String: Any])
        XCTAssertNil(tour["artist_name_raw"])
        let event = try XCTUnwrap(body["event"] as? [String: Any])
        XCTAssertNil(event["venue_name_raw"])
    }

    // MARK: - PATCH（送らない / null を送る の区別）

    private func encodedUpdateBody(_ patch: ApplicationPatch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(UpdateApplicationRequest(patch: patch))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUpdateRequestOmitsUnchangedKeys() throws {
        var patch = ApplicationPatch()
        patch.status = .set(.lost)
        let body = try encodedUpdateBody(patch)
        XCTAssertEqual(body.count, 1, "触っていないキーは送らない（座席を消さない）")
        XCTAssertEqual(body["status"] as? String, "lost")
        XCTAssertNil(body["seat_raw"])
        XCTAssertNil(body["companions"])
    }

    func testUpdateRequestSendsExplicitNullForClearedSeat() throws {
        var patch = ApplicationPatch()
        patch.seatRaw = .set(nil)
        let body = try encodedUpdateBody(patch)
        XCTAssertTrue(body["seat_raw"] is NSNull)
    }

    func testUpdateRequestCannotSendTourOrEventID() throws {
        var patch = ApplicationPatch()
        patch.status = .set(.won)
        patch.seatRaw = .set("アリーナ8列")
        patch.companions = .set([Companion(id: UUID(), identityID: identityA, displayName: "妹", position: 4)])
        let body = try encodedUpdateBody(patch)
        XCTAssertNil(body["tour_id"], "PATCH で tour_id は送れない（BE は 400）")
        XCTAssertNil(body["event_id"])
        let companions = try XCTUnwrap(body["companions"] as? [[String: Any]])
        XCTAssertEqual(companions[0]["position"] as? Int, 0, "全置換時も position は 0 起点")
    }

    func testUpdateTourAndEventRequestsUseContractKeys() throws {
        var tourPatch = TourPatch()
        tourPatch.artistNameRaw = .set("ARTIST")
        let tourBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(UpdateTourRequest(patch: tourPatch)))
                as? [String: Any]
        )
        XCTAssertEqual(tourBody["artist_name_raw"] as? String, "ARTIST")
        XCTAssertNil(tourBody["name"])

        var eventPatch = EventPatch()
        eventPatch.eventDate = .set(jst(2026, 8, 20))
        eventPatch.venueNameRaw = .set(nil)
        let eventBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(UpdateEventRequest(patch: eventPatch)))
                as? [String: Any]
        )
        XCTAssertEqual(eventBody["event_date"] as? String, "2026-08-20")
        XCTAssertTrue(eventBody["venue_name_raw"] is NSNull)
        XCTAssertNil(eventBody["tour_id"], "tour_id の付け替えは不可（型として持たない）")
    }

    // MARK: - ヘルパー

    private func jst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}
