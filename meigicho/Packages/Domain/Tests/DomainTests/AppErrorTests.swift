import XCTest
@testable import Domain

/// AC-N-05-T / AC-N-06-T
final class AppErrorTests: XCTestCase {
    private func envelope(_ json: String) throws -> APIErrorEnvelope {
        try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(json.utf8))
    }

    // AC-N-05-T: 未知の code を既知ケースに丸めない
    func testUnknownCodeStaysUnknown() throws {
        let env = try envelope(#"{"code":"TEAPOT_ERROR","message":"m","request_id":"req-1"}"#)
        XCTAssertEqual(AppError.from(envelope: env), .unknown(code: "TEAPOT_ERROR", message: "m"))
    }

    func testUnknownCodeIsNotRoundedToConflictOrServer() throws {
        for code in ["PLAN_LIMIT_SOMETHING", "AUTH_MAGIC_INVALID", "SHARE_WEIRD", ""] {
            let env = try envelope(#"{"code":"\#(code)","message":null}"#)
            let mapped = AppError.from(envelope: env)
            guard case .unknown(let mappedCode, _) = mapped else {
                return XCTFail("\(code) should map to .unknown but was \(mapped)")
            }
            XCTAssertEqual(mappedCode, code)
        }
    }

    func testKnownCodesMapToDedicatedCases() throws {
        let expectations: [(String, AppError)] = [
            ("VALIDATION_ERROR", .validation(message: "m")),
            ("UNAUTHENTICATED", .unauthenticated),
            ("AUTH_APPLE_INVALID", .appleSignInFailed),
            ("AUTH_GOOGLE_INVALID", .googleSignInFailed),
            ("AUTH_CREDENTIALS_INVALID", .credentialsInvalid),
            ("AUTH_RESET_CODE_INVALID", .resetCodeInvalid),
            ("AUTH_REFRESH_INVALID", .sessionExpired),
            ("FORBIDDEN", .forbidden),
            ("NOT_FOUND", .notFound),
            ("SHARE_INVALID", .shareInvalid),
            ("EMAIL_ALREADY_REGISTERED", .emailAlreadyRegistered),
            ("CONFLICT", .conflict),
            ("RATE_LIMITED", .rateLimited),
            ("INTERNAL", .server),
        ]
        for (code, expected) in expectations {
            let env = try envelope(#"{"code":"\#(code)","message":"m"}"#)
            XCTAssertEqual(AppError.from(envelope: env), expected, "code=\(code)")
        }
    }

    // 汎用マッパーは CONFLICT を必ず .conflict にする（格上げは RemoteSharedBoardRepository だけ）
    func testGenericMapperNeverProducesShareItemConflict() throws {
        let env = try envelope(#"""
        {"code":"CONFLICT","message":"m","details":{"current":{"status":"won","seat":"A-1","rev":"r2"}}}
        """#)
        XCTAssertEqual(AppError.from(envelope: env), .conflict)
    }

    // AC-N-06-T: details 欠落 / 型不一致でもクラッシュしない
    func testPlanLimitDetailsAreParsed() throws {
        let env = try envelope(#"{"code":"PLAN_LIMIT_IDENTITY","message":"m","details":{"limit":3,"current":3}}"#)
        XCTAssertEqual(AppError.from(envelope: env), .planLimitIdentity(limit: 3, current: 3))
    }

    func testPlanLimitWithMissingDetails() throws {
        let env = try envelope(#"{"code":"PLAN_LIMIT_IDENTITY","message":"m"}"#)
        XCTAssertEqual(AppError.from(envelope: env), .planLimitIdentity(limit: nil, current: nil))
    }

    func testPlanLimitWithMistypedDetails() throws {
        let cases = [
            #"{"code":"PLAN_LIMIT_SHARE","message":"m","details":{"limit":"3","current":true}}"#,
            #"{"code":"PLAN_LIMIT_SHARE","message":"m","details":[]}"#,
            #"{"code":"PLAN_LIMIT_SHARE","message":"m","details":null}"#,
            #"{"code":"PLAN_LIMIT_SHARE","message":"m","details":{"limit":{"x":1}}}"#,
        ]
        for json in cases {
            let env = try envelope(json)
            XCTAssertEqual(AppError.from(envelope: env), .planLimitShare(limit: nil, current: nil), "json=\(json)")
        }
    }

    func testPlanLimitShareWriteHasItsOwnCase() throws {
        let env = try envelope(#"{"code":"PLAN_LIMIT_SHARE_WRITE","message":"m","details":{"limit":3,"current":5}}"#)
        XCTAssertEqual(AppError.from(envelope: env), .planLimitShareWrite(limit: 3, current: 5))
    }

    func testRequestIDIsDecodedFromSnakeCaseKey() throws {
        let env = try envelope(#"{"code":"INTERNAL","message":"m","request_id":"req-42"}"#)
        XCTAssertEqual(env.requestID, "req-42")
    }

    func testUserMessageIsAvailableForEveryCase() {
        let errors: [AppError] = [
            .validation(message: "x"), .unauthenticated, .appleSignInFailed, .googleSignInFailed,
            .credentialsInvalid, .resetCodeInvalid, .sessionExpired, .forbidden,
            .planLimitIdentity(limit: 3, current: 3), .planLimitShare(limit: nil, current: nil),
            .planLimitShareWrite(limit: 3, current: 5), .notFound, .shareInvalid,
            .emailAlreadyRegistered, .conflict,
            .shareItemConflict(current: SharedItemSnapshot(status: .won, seat: nil, rev: "r")),
            .rateLimited, .server, .unknown(code: "X", message: nil), .decoding("d"),
            .offline, .timeout, .transport(URLError(.cannotConnectToHost)),
        ]
        for error in errors {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error)")
        }
    }

    // サーバーの message をそのまま UI に出さない（開発ビルドでのみ付記する）
    func testValidationUserMessageDoesNotLeakServerMessage() {
        let message = AppError.validation(message: "email must be an email").userMessage
        XCTAssertTrue(message.hasPrefix("入力内容を確認してください"))
    }

    func testURLErrorMapping() {
        XCTAssertEqual(AppError.from(urlError: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(AppError.from(urlError: URLError(.timedOut)), .timeout)
        XCTAssertEqual(AppError.from(urlError: URLError(.cannotFindHost)), .transport(URLError(.cannotFindHost)))
    }
}
