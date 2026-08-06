import XCTest
import Core
import Domain
@testable import Network

/// T4b（共有ボード・受け取り側）の DTO 契約。`contract-mapping.md` §4.8 / `api-contract-delta.md` §4。
///
/// AC-SB-03/04/05 は `plan.md` §4.5b では `DomainTests` と書かれているが、
/// 対象の型（`UpdateSharedItemRequest` / `RemoteSharedBoardRepository`）は `Network` にあるため
/// こちらに置いた（`ShareDTOTests` と同じ扱い）。
final class SharedBoardDTOTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let logger = AppLogger(category: "test")

    private func encodedObject(_ request: UpdateSharedItemRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - AC-SB-01-T: read リンクは item_key / rev / editable がキーごと無い

    func testReadPayloadDecodesWithoutHandleKeys() throws {
        let json = """
        {
          "scope_type": "tour",
          "permission": "read",
          "tour": { "name": "STELLARIS LIVE TOUR 2026", "artist_name": "STELLARIS" },
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [
            {
              "event_name": "大阪公演 Day1",
              "venue": "大阪城ホール",
              "event_date": "2026-08-20",
              "round_name": "FC1次",
              "rep_name": "自分",
              "rep_color": "#0017C1",
              "companions": ["妹"],
              "status": "applied",
              "seat": null
            }
          ]
        }
        """
        let response = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8))
        let board = response.toDomain(logger: logger)

        XCTAssertEqual(board.permission, .read)
        XCTAssertEqual(board.scopeType, .tour)
        XCTAssertEqual(board.tourName, "STELLARIS LIVE TOUR 2026")
        XCTAssertEqual(board.artistName, "STELLARIS")
        XCTAssertEqual(board.items.count, 1)

        let item = try XCTUnwrap(board.items.first)
        // **`editable ?? true` にしない**。3 キーが無いので handle は nil = 編集不可
        XCTAssertNil(item.handle)
        XCTAssertNil(item.seat)
        XCTAssertEqual(item.status, .applied)
        XCTAssertEqual(item.companions, ["妹"])
        XCTAssertEqual(item.eventDate, APIDateFormat.dateOnly(from: "2026-08-20"))
    }

    func testWritePayloadDecodesHandlePerItem() throws {
        let json = """
        {
          "scope_type": "tour",
          "permission": "write",
          "tour": { "name": "T", "artist_name": null },
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [
            { "event_name": "Day1", "venue": null, "event_date": null, "round_name": null,
              "rep_name": "自分", "rep_color": null, "companions": [], "status": "applied",
              "seat": "", "item_key": "b3RhLWtleS1zYW1wbGUx", "rev": "cmV2LXNhbXBsZQ", "editable": true },
            { "event_name": "Day2", "venue": null, "event_date": null, "round_name": null,
              "rep_name": "非公開の名義", "rep_color": null, "companions": [], "status": "applied",
              "seat": null, "item_key": "cWlxLWtleS1zYW1wbGUy", "rev": "cmV2LXNhbXBsZTI", "editable": false }
          ]
        }
        """
        let board = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8)).toDomain(logger: logger)

        XCTAssertEqual(board.permission, .write)
        XCTAssertEqual(board.items[0].handle?.itemKey, "b3RhLWtleS1zYW1wbGUx")
        XCTAssertEqual(board.items[0].handle?.rev, "cmV2LXNhbXBsZQ")
        XCTAssertEqual(board.items[0].handle?.editable, true)
        // P5: 空文字を nil に丸めない
        XCTAssertEqual(board.items[0].seat, "")
        XCTAssertEqual(board.items[1].handle?.editable, false)
        XCTAssertNil(board.items[1].seat)
        // P3: item_key をそのまま Identifiable.id に使う
        XCTAssertEqual(board.items[0].id, "b3RhLWtleS1zYW1wbGUx")
    }

    /// P4: 未知の status は `.applied` にフォールバックする（クラッシュもデコード失敗もしない）。
    func testUnknownStatusFallsBackToApplied() throws {
        let json = """
        { "event_name": "Day1", "venue": null, "event_date": null, "round_name": null,
          "rep_name": "自分", "rep_color": null, "companions": [], "status": "refunded", "seat": null }
        """
        let item = try decoder.decode(SharedBoardItemResponse.self, from: Data(json.utf8)).toDomain(logger: logger)
        XCTAssertEqual(item.status, .applied)
        XCTAssertNil(item.handle)
    }

    // MARK: - identity_summary（**tour とは items の形が完全に別物**）

    /// `scope_type: "identity_summary"` は `tour` キーが無く、items も別形。
    /// `visible: false` の行は**件数キー自体が来ない**（`public-share.presenter.ts` の `toIdentitySummaryItem`）。
    func testIdentitySummaryPayloadDecodes() throws {
        let json = """
        {
          "scope_type": "identity_summary",
          "permission": "read",
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [
            { "name": "自分", "visible": true, "application_count": 12, "won_count": 5 },
            { "name": "友人A", "visible": false }
          ]
        }
        """
        let board = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8)).toDomain(logger: logger)

        XCTAssertEqual(board.scopeType, .identitySummary)
        XCTAssertEqual(board.permission, .read)
        XCTAssertNil(board.tourName)
        XCTAssertNil(board.artistName)
        // tour の行としては 1 件も生えない（型で別物 — P6）
        XCTAssertTrue(board.items.isEmpty)

        let rows = board.identitySummaries
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "自分")
        XCTAssertEqual(rows[0].counts, SharedIdentityCounts(applicationCount: 12, wonCount: 5))
        XCTAssertTrue(rows[0].isVisible)
        // 件数キーが無くてもクラッシュもデコード失敗もしない
        XCTAssertEqual(rows[1].name, "友人A")
        XCTAssertNil(rows[1].counts)
        XCTAssertFalse(rows[1].isVisible)
        // 同名の名義が並んでも id は衝突しない
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    func testIdentitySummaryWithDuplicateNamesHasDistinctIDs() throws {
        let json = """
        {
          "scope_type": "identity_summary",
          "permission": "read",
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [
            { "name": "自分", "visible": false },
            { "name": "自分", "visible": false }
          ]
        }
        """
        let rows = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8))
            .toDomain(logger: logger).identitySummaries
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    /// 契約違反（`visible: true` なのに件数キーが無い）でも落ちない。
    /// **件数を 0 と偽らず「非公開」に倒す**（マスキング側に倒す）。
    func testIdentitySummaryVisibleWithoutCountsFallsBackToHidden() throws {
        let json = """
        {
          "scope_type": "identity_summary",
          "permission": "read",
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [{ "name": "自分", "visible": true }]
        }
        """
        let rows = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8))
            .toDomain(logger: logger).identitySummaries
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].counts)
    }

    /// `visible: false` に件数が付いてきても**出さない**（マスキングを弱めない）。
    func testIdentitySummaryHiddenRowNeverExposesCounts() throws {
        let json = """
        {
          "scope_type": "identity_summary",
          "permission": "read",
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [{ "name": "友人A", "visible": false, "application_count": 3, "won_count": 1 }]
        }
        """
        let rows = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8))
            .toDomain(logger: logger).identitySummaries
        XCTAssertNil(rows[0].counts)
    }

    /// identity_summary は書き込み経路が無いので、`permission` が欠けたら
    /// **最も制限の強い `read`** として扱う（write に倒さない）。
    func testIdentitySummaryWithoutPermissionIsRead() throws {
        let json = """
        {
          "scope_type": "identity_summary",
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [{ "name": "自分", "visible": true, "application_count": 1, "won_count": 0 }]
        }
        """
        let board = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8)).toDomain(logger: logger)
        XCTAssertEqual(board.permission, .read)
    }

    /// tour スコープでは `permission` を勝手に補わない（欠けたらデコード失敗させる）。
    func testTourPayloadRequiresPermission() {
        let json = """
        {
          "scope_type": "tour",
          "tour": { "name": "T", "artist_name": null },
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": []
        }
        """
        XCTAssertThrowsError(try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8)))
    }

    /// 未知の `scope_type` は tour にも identity_summary にも黙って落とさない（BE-2 の iOS 版）。
    func testUnknownScopeTypeFailsDecoding() {
        let json = """
        { "scope_type": "calendar", "permission": "read", "generated_at": "2026-08-02T10:00:00.000Z", "items": [] }
        """
        XCTAssertThrowsError(try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8)))
    }

    // MARK: - read リンクの行 id（`ForEach` の id 衝突）

    /// 同一公演・同一名義でラウンド違いの申込が並んでも id が衝突しない。
    /// （`item_key` が無い read リンクでの `ForEach` 取り違え対策）
    func testReadLinkRowIDsAreUniqueAcrossRounds() throws {
        let json = """
        {
          "scope_type": "tour",
          "permission": "read",
          "tour": { "name": "T", "artist_name": null },
          "generated_at": "2026-08-02T10:00:00.000Z",
          "items": [
            { "event_name": "大阪公演 Day1", "venue": null, "event_date": "2026-08-20", "round_name": "FC1次",
              "rep_name": "非公開の名義", "rep_color": null, "companions": [], "status": "applied", "seat": null },
            { "event_name": "大阪公演 Day1", "venue": null, "event_date": "2026-08-20", "round_name": "FC2次",
              "rep_name": "非公開の名義", "rep_color": null, "companions": [], "status": "lost", "seat": null },
            { "event_name": "大阪公演 Day1", "venue": null, "event_date": "2026-08-20", "round_name": "FC2次",
              "rep_name": "非公開の名義", "rep_color": null, "companions": [], "status": "won", "seat": null }
          ]
        }
        """
        let board = try decoder.decode(SharedBoardResponse.self, from: Data(json.utf8)).toDomain(logger: logger)
        XCTAssertEqual(Set(board.items.map(\.id)).count, 3)
    }

    // MARK: - AC-SB-02-T: handle は 3 つ揃ったときだけできる

    func testHandleRequiresAllThreeKeys() {
        XCTAssertNotNil(SharedItemHandle(itemKey: "k", rev: "r", editable: true))
        XCTAssertNil(SharedItemHandle(itemKey: "k", rev: nil, editable: true))
        XCTAssertNil(SharedItemHandle(itemKey: nil, rev: "r", editable: true))
        XCTAssertNil(SharedItemHandle(itemKey: "k", rev: "r", editable: nil))
        XCTAssertNil(SharedItemHandle(itemKey: nil, rev: nil, editable: nil))
    }

    // MARK: - AC-SB-03-T: body は rev + (status か seat) のみ。3 キー以外を送らない

    func testStatusOnlyBodyHasRevAndStatusOnly() throws {
        let object = try encodedObject(UpdateSharedItemRequest(rev: "R1", change: .status(.won)))
        XCTAssertEqual(Set(object.keys), ["rev", "status"])
        XCTAssertEqual(object["rev"] as? String, "R1")
        XCTAssertEqual(object["status"] as? String, "won")
    }

    func testSeatOnlyBodyHasRevAndSeatOnly() throws {
        let object = try encodedObject(UpdateSharedItemRequest(rev: "R1", change: .seat("1F A列 12番")))
        XCTAssertEqual(Set(object.keys), ["rev", "seat"])
        XCTAssertEqual(object["seat"] as? String, "1F A列 12番")
    }

    func testStatusAndSeatBodyHasExactlyThreeKeys() throws {
        let object = try encodedObject(
            UpdateSharedItemRequest(rev: "R1", change: .statusAndSeat(.lost, "S"))
        )
        XCTAssertEqual(Set(object.keys), ["rev", "status", "seat"])
    }

    /// `SharedItemChange` からしか作れないので、**空ボディ（rev だけ）を型で作れない**。
    func testEveryChangeCarriesAtLeastStatusOrSeat() throws {
        let changes: [SharedItemChange] = [
            .status(.draft), .seat(nil), .seat(""), .statusAndSeat(.won, nil),
        ]
        for change in changes {
            let object = try encodedObject(UpdateSharedItemRequest(rev: "R", change: change))
            XCTAssertNotNil(object.index(forKey: "rev"))
            XCTAssertTrue(
                object.index(forKey: "status") != nil || object.index(forKey: "seat") != nil,
                "status / seat のどちらも無いボディは 400 になる"
            )
            XCTAssertTrue(Set(object.keys).isSubset(of: ["rev", "status", "seat"]))
        }
    }

    // MARK: - AC-SB-04-T: seat の 3 状態（送らない / null / 空文字）

    func testSeatHasThreeDistinctWireStates() throws {
        // ① 送らない
        let notSent = try JSONEncoder().encode(UpdateSharedItemRequest(rev: "R", change: .status(.won)))
        let notSentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: notSent) as? [String: Any])
        XCTAssertNil(notSentObject.index(forKey: "seat"))

        // ② null を送る（座席を消す）
        let nullSent = try JSONEncoder().encode(UpdateSharedItemRequest(rev: "R", change: .seat(nil)))
        XCTAssertTrue(String(decoding: nullSent, as: UTF8.self).contains("\"seat\":null"))

        // ③ 空文字を送る（**null に丸めない**）
        let emptySent = try JSONEncoder().encode(UpdateSharedItemRequest(rev: "R", change: .seat("")))
        XCTAssertTrue(String(decoding: emptySent, as: UTF8.self).contains("\"seat\":\"\""))
        XCTAssertFalse(String(decoding: emptySent, as: UTF8.self).contains("null"))
    }

    // MARK: - AC-SB-05-T: CONFLICT + details.current の格上げ

    func testConflictWithCurrentDetailsIsPromoted() throws {
        let json = """
        {
          "code": "CONFLICT",
          "message": "share item was updated by someone else",
          "details": { "current": { "status": "lost", "seat": null, "rev": "Y3VycmVudC1yZXY" } },
          "request_id": "018f3c2a-9999-7c90-9d2a-000000000001"
        }
        """
        let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(json.utf8))
        let promoted = RemoteSharedBoardRepository.promoteShareItemConflict(envelope)
        XCTAssertEqual(
            promoted,
            .shareItemConflict(current: SharedItemSnapshot(status: .lost, seat: nil, rev: "Y3VycmVudC1yZXY"))
        )
    }

    func testConflictKeepsSeatEmptyStringAsEmptyString() throws {
        let json = """
        { "code": "CONFLICT", "details": { "current": { "status": "won", "seat": "", "rev": "R2" } } }
        """
        let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(
            RemoteSharedBoardRepository.promoteShareItemConflict(envelope),
            .shareItemConflict(current: SharedItemSnapshot(status: .won, seat: "", rev: "R2"))
        )
    }

    /// `details` が読めなければ格上げしない（`.conflict` のまま）。
    func testUnreadableConflictDetailsAreNotPromoted() throws {
        let payloads = [
            #"{ "code": "CONFLICT" }"#,
            #"{ "code": "CONFLICT", "details": {} }"#,
            #"{ "code": "CONFLICT", "details": { "current": {} } }"#,
            #"{ "code": "CONFLICT", "details": { "current": { "status": "won" } } }"#,
            #"{ "code": "CONFLICT", "details": { "current": { "status": "won", "rev": 12 } } }"#,
            #"{ "code": "CONFLICT", "details": { "current": { "status": "won", "seat": 3, "rev": "R" } } }"#,
            #"{ "code": "CONFLICT", "details": "nope" }"#,
        ]
        for payload in payloads {
            let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(payload.utf8))
            XCTAssertNil(
                RemoteSharedBoardRepository.promoteShareItemConflict(envelope),
                "\(payload) は格上げしない"
            )
            // 汎用マッパーの結果（= 格上げしなかったときの値）は .conflict
            XCTAssertEqual(AppError.from(envelope: envelope), .conflict)
        }
    }

    /// 他のコードは格上げの対象にしない。
    func testOnlyConflictCodeIsPromoted() throws {
        for code in ["SHARE_INVALID", "FORBIDDEN", "RATE_LIMITED", "VALIDATION_ERROR"] {
            let json = #"{ "code": "\#(code)", "details": { "current": { "status": "won", "seat": null, "rev": "R" } } }"#
            let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(json.utf8))
            XCTAssertNil(RemoteSharedBoardRepository.promoteShareItemConflict(envelope))
        }
    }

    // MARK: - エンドポイント（`/v1` を付けない）

    func testSharedBoardEndpointsAreNotVersioned() throws {
        let get = Endpoint.publicPath(.get, "/public/shares/TOKEN")
        let request = try get.urlRequest(baseURL: URL(string: "http://localhost:8080")!, extraHeaders: [:])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/public/shares/TOKEN")
        // **Bearer を付けない**
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
