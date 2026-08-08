import XCTest
import Domain
@testable import Network

/// `RemoteShareRepository` の縦串: 招待の追加・削除・`SHARE_RECIPIENT_UNKNOWN` の格上げ。
/// `api-contract-delta.md` §1 / §3 / §6.3。
final class RemoteShareRepositoryTests: XCTestCase {
    private var recorder: StubRecorder!
    private var repository: RemoteShareRepository!

    private let shareID = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!

    override func setUp() async throws {
        try await super.setUp()
        recorder = StubRecorder()
        StubURLProtocol.recorder = recorder
        let client = ApiClient(
            configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            tokenStore: InMemoryTokenStore(token: "refresh-1"),
            session: StubURLProtocol.makeSession()
        )
        await client.adoptSession(
            TokenPair(accessToken: "at-1", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600))
        )
        repository = RemoteShareRepository(client: client)
    }

    override func tearDown() async throws {
        StubURLProtocol.recorder = nil
        recorder = nil
        repository = nil
        try await super.tearDown()
    }

    // MARK: - addRecipients / removeRecipient の配線

    func testAddRecipientsPostsToRecipientsPathAndReturnsAllEntries() async throws {
        recorder.respond { _ in
            StubResponse(status: 200, body: Data("""
            { "recipients": [
              { "account_id": "ACC-1A2B3C", "display_name": null,
                "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null }
            ] }
            """.utf8))
        }

        let recipients = try await repository.addRecipients(shareID: shareID, accountIDs: ["ACC-1A2B3C"])

        XCTAssertEqual(recipients.map(\.accountID), ["ACC-1A2B3C"])
        XCTAssertEqual(recorder.count(path: "/v1/shares/\(shareID.uuidString.lowercased())/recipients"), 1)
    }

    func testRemoveRecipientSendsDeleteWithAccountIDInPath() async throws {
        recorder.respond { _ in StubResponse(status: 204, body: Data()) }

        try await repository.removeRecipient(shareID: shareID, accountID: "ACC-1A2B3C")

        XCTAssertEqual(
            recorder.count(path: "/v1/shares/\(shareID.uuidString.lowercased())/recipients/ACC-1A2B3C"),
            1
        )
    }

    // MARK: - `SHARE_RECIPIENT_UNKNOWN` の格上げ（§6.3）

    /// `create` が `SHARE_RECIPIENT_UNKNOWN` + `details.unknown_account_ids` を
    /// `.shareRecipientUnknown(accountIDs:)` に格上げする。
    func testCreatePromotesRecipientUnknownWithAccountIDs() async {
        recorder.respond { _ in
            StubResponse(status: 400, body: Data("""
            { "code": "SHARE_RECIPIENT_UNKNOWN", "message": "unknown accounts",
              "details": { "unknown_account_ids": ["ACC-000000"] } }
            """.utf8))
        }

        do {
            _ = try await repository.create(.identitySummary, maskMemberNo: true, sharedWithAccountIDs: ["ACC-000000"])
            XCTFail("400 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .shareRecipientUnknown(accountIDs: ["ACC-000000"]))
        }
    }

    /// `addRecipients` も同じ格上げを行う。
    func testAddRecipientsPromotesRecipientUnknown() async {
        recorder.respond { _ in
            StubResponse(status: 400, body: Data("""
            { "code": "SHARE_RECIPIENT_UNKNOWN",
              "details": { "unknown_account_ids": ["ACC-111111", "ACC-222222"] } }
            """.utf8))
        }

        do {
            _ = try await repository.addRecipients(shareID: shareID, accountIDs: ["ACC-111111", "ACC-222222"])
            XCTFail("400 は throw されるべき")
        } catch {
            XCTAssertEqual(
                error as? AppError,
                .shareRecipientUnknown(accountIDs: ["ACC-111111", "ACC-222222"])
            )
        }
    }

    /// `details` が読めなければ格上げしない（汎用マッパーは空配列）。
    func testRecipientUnknownWithoutDetailsIsNotPromoted() {
        let envelope = APIErrorEnvelope(code: "SHARE_RECIPIENT_UNKNOWN", message: nil, details: nil, requestID: nil)
        XCTAssertNil(RemoteShareRepository.promoteRecipientUnknown(envelope))
        XCTAssertEqual(AppError.from(envelope: envelope), .shareRecipientUnknown(accountIDs: []))
    }

    /// 他のコードは格上げの対象にしない。
    func testOnlyRecipientUnknownCodeIsPromoted() {
        let envelope = APIErrorEnvelope(
            code: "VALIDATION_ERROR",
            message: nil,
            details: .object(["unknown_account_ids": .array([.string("ACC-000000")])]),
            requestID: nil
        )
        XCTAssertNil(RemoteShareRepository.promoteRecipientUnknown(envelope))
    }

    /// 要素の型が違うものが混ざっていたら黙って一部だけ拾わず、格上げしない。
    func testRecipientUnknownWithNonStringElementIsNotPromoted() {
        let envelope = APIErrorEnvelope(
            code: "SHARE_RECIPIENT_UNKNOWN",
            message: nil,
            details: .object(["unknown_account_ids": .array([.string("ACC-000000"), .number(1)])]),
            requestID: nil
        )
        XCTAssertNil(RemoteShareRepository.promoteRecipientUnknown(envelope))
    }
}
