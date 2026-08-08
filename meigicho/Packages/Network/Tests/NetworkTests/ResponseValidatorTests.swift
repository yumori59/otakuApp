import XCTest
import Domain
@testable import Network

/// envelope → `AppError` の変換が `Domain.AppError.from(envelope:)` に集約されていること。
final class ResponseValidatorTests: XCTestCase {
    private let url = URL(string: "http://localhost:8080/v1/identities")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testSuccessPassesThrough() throws {
        XCTAssertNoThrow(try ResponseValidator.validate(data: Data("{}".utf8), response: response(200)))
        XCTAssertNoThrow(try ResponseValidator.validate(data: Data(), response: response(204)))
    }

    func testEnvelopeIsMappedThroughDomain() throws {
        let body = Data(#"{"code":"PLAN_LIMIT_IDENTITY","message":"m","details":{"limit":3,"current":3}}"#.utf8)
        XCTAssertThrowsError(try ResponseValidator.validate(data: body, response: response(403))) { error in
            XCTAssertEqual(error as? AppError, .planLimitIdentity(limit: 3, current: 3))
        }
    }

    func testUnknownCodeIsNotRounded() throws {
        let body = Data(#"{"code":"WHO_KNOWS","message":"m"}"#.utf8)
        XCTAssertThrowsError(try ResponseValidator.validate(data: body, response: response(418))) { error in
            XCTAssertEqual(error as? AppError, .unknown(code: "WHO_KNOWS", message: "m"))
        }
    }

    func testNonEnvelopeBodyBecomesDecodingError() throws {
        let body = Data("<html>502 Bad Gateway</html>".utf8)
        XCTAssertThrowsError(try ResponseValidator.validate(data: body, response: response(502))) { error in
            guard case .decoding? = error as? AppError else {
                return XCTFail("expected .decoding but got \(error)")
            }
        }
    }

    // 汎用の変換は共有 item の CONFLICT を格上げしない（格上げは RemoteSharedBoardRepository のみ）
    func testConflictStaysGeneric() throws {
        let body = Data(#"{"code":"CONFLICT","details":{"current":{"status":"won","seat":null,"rev":"r"}}}"#.utf8)
        XCTAssertThrowsError(try ResponseValidator.validate(data: body, response: response(409))) { error in
            XCTAssertEqual(error as? AppError, .conflict)
        }
    }
}

/// AC-N-13 の一部（実装 grep とレビューで担保する残りは報告に記載）
///
/// 旧 `PublicApiClient` は `api-contract-delta.md` Q1=A で廃止された
/// （`/public/shares/:token` 系が無くなり、`ApiClient` 1 種類に統一された）。
final class ClientSeparationTests: XCTestCase {
    func testAuthenticatedClientRejectsPublicEndpoints() async {
        let client = ApiClient(configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!))
        do {
            _ = try await client.sendVoid(Endpoint.publicPath(.get, "/public/shares/x"))
            XCTFail("public endpoint must not be sent by ApiClient")
        } catch let error as AppError {
            guard case .decoding = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
