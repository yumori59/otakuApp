import XCTest
import Security
@testable import Networking

/// Keychain 書き込み失敗を握りつぶさない（中-3）。
///
/// 実際の Keychain はテストプロセスで安定して叩けないので、
/// **「どの OSStatus を失敗として記録するか」の判定だけ**を純関数として検証する。
final class KeychainWriteTests: XCTestCase {

    func testSuccessProducesNoEvent() {
        XCTAssertNil(KeychainWrite.failureEvent(operation: .update, status: errSecSuccess))
        XCTAssertNil(KeychainWrite.failureEvent(operation: .add, status: errSecSuccess))
        XCTAssertNil(KeychainWrite.failureEvent(operation: .delete, status: errSecSuccess))
    }

    /// `SecItemUpdate` の `errSecItemNotFound` は「まだ無いので追加する」の合図。失敗ではない。
    func testUpdateItemNotFoundIsNotAFailure() {
        XCTAssertNil(KeychainWrite.failureEvent(operation: .update, status: errSecItemNotFound))
    }

    /// `SecItemDelete` の `errSecItemNotFound` は「既に無い」。失敗ではない。
    func testDeleteItemNotFoundIsNotAFailure() {
        XCTAssertNil(KeychainWrite.failureEvent(operation: .delete, status: errSecItemNotFound))
    }

    /// `SecItemAdd` が `errSecItemNotFound` を返すのは異常。記録する。
    func testAddItemNotFoundIsAFailure() {
        XCTAssertNotNil(KeychainWrite.failureEvent(operation: .add, status: errSecItemNotFound))
    }

    func testFailureEventCarriesOperationAndStatusOnly() throws {
        let event = try XCTUnwrap(
            KeychainWrite.failureEvent(operation: .update, status: errSecInteractionNotAllowed)
        )
        XCTAssertEqual(event, "keychain_update_failed_\(errSecInteractionNotAllowed)")
        // 固定イベント名 + OSStatus だけ（token / service / account を含めない — NFR-4）
        XCTAssertFalse(event.contains("token"))
        XCTAssertFalse(event.contains("jp.meigicho"))
    }

    func testEveryNonSuccessStatusIsReported() {
        let statuses: [OSStatus] = [
            errSecDuplicateItem, errSecAuthFailed, errSecInteractionNotAllowed,
            errSecMissingEntitlement, errSecParam, -34018,
        ]
        for status in statuses {
            XCTAssertNotNil(KeychainWrite.failureEvent(operation: .update, status: status), "\(status)")
            XCTAssertNotNil(KeychainWrite.failureEvent(operation: .add, status: status), "\(status)")
        }
    }
}
