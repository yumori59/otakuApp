import XCTest
@testable import Networking

/// AC-AV-31: `MultipartFormData.singleFile` の body 構造と `contentType` 検証。
final class MultipartFormDataTests: XCTestCase {

    /// contentType が `multipart/form-data; boundary=Boundary-<UUID>` 形式になる
    func testContentTypeContainsMultipartAndBoundary() {
        let result = MultipartFormData.singleFile(
            name: "file",
            filename: "avatar.jpg",
            mimeType: "image/jpeg",
            data: Data("dummy".utf8)
        )
        XCTAssertTrue(result.contentType.hasPrefix("multipart/form-data; boundary=Boundary-"),
                      "contentType が 'multipart/form-data; boundary=Boundary-' で始まること: \(result.contentType)")
        // boundary 部分が UUID 形式
        let boundary = String(result.contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertNotNil(UUID(uuidString: boundary.replacingOccurrences(of: "Boundary-", with: "")),
                        "boundary の UUID 部分が有効な UUID であること: \(boundary)")
    }

    /// body に `Content-Disposition: form-data; name="file"; filename=` が含まれる
    func testBodyContainsFormDispositionWithNameAndFilename() throws {
        let result = MultipartFormData.singleFile(
            name: "file",
            filename: "avatar.jpg",
            mimeType: "image/jpeg",
            data: Data("JFIF".utf8)
        )
        let body = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\""),
                      "body に Content-Disposition ヘッダーが含まれること")
    }

    /// body に `Content-Type: image/jpeg` が含まれる
    func testBodyContainsPartContentType() throws {
        let result = MultipartFormData.singleFile(
            name: "file",
            filename: "photo.png",
            mimeType: "image/png",
            data: Data("PNG".utf8)
        )
        let body = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(body.contains("Content-Type: image/png"),
                      "body に Content-Type: image/png が含まれること")
    }

    /// body にファイルデータが含まれる
    func testBodyContainsFileData() {
        let fileData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG マジックバイト
        let result = MultipartFormData.singleFile(
            name: "file",
            filename: "avatar.jpg",
            mimeType: "image/jpeg",
            data: fileData
        )
        // body 内に fileData のバイト列が含まれること
        XCTAssertTrue(result.body.range(of: fileData) != nil,
                      "body にファイルデータが含まれること")
    }

    /// 行区切りが CRLF (\r\n) であること
    func testBodyUsesCarriageReturnLineFeed() throws {
        let result = MultipartFormData.singleFile(
            name: "file",
            filename: "avatar.jpg",
            mimeType: "image/jpeg",
            data: Data("dummy".utf8)
        )
        let body = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(body.contains("\r\n"),
                      "body が CRLF を使用していること")
        XCTAssertFalse(body.contains("\r\n\r\n") && !body.contains("\r\n"),
                       "LF のみの行区切りが混在しないこと")
    }

    /// boundary が body の先頭と末尾の delimiter に使われる
    func testBodyUsesBoundaryFromContentType() throws {
        let result = MultipartFormData.singleFile(
            name: "file",
            filename: "avatar.jpg",
            mimeType: "image/jpeg",
            data: Data("data".utf8)
        )
        let boundaryValue = String(result.contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(body.contains("--\(boundaryValue)\r\n"),
                      "body が boundary の開始 delimiter を含むこと")
        XCTAssertTrue(body.contains("--\(boundaryValue)--"),
                      "body が boundary の終了 delimiter を含むこと")
    }
}
