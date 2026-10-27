import Foundation

/// `PUT /v1/me/avatar` 用の `multipart/form-data` ボディを組み立てる（`api-contract-delta.md` §2）。
///
/// 単一ファイルパートのみを対象とした最小実装。
/// 改行は CRLF（RFC 2046）、境界は `"Boundary-" + UUID`（推測不能かつ一意）。
public enum MultipartFormData {
    /// 単一ファイルパートの `multipart/form-data` ボディと `Content-Type` 文字列を生成する。
    ///
    /// - Parameters:
    ///   - name: `Content-Disposition` の `name` 属性（例: `"file"`）。
    ///   - filename: `Content-Disposition` の `filename` 属性（例: `"avatar.jpg"`）。
    ///   - mimeType: パートの `Content-Type`（例: `"image/jpeg"`）。
    ///   - data: ファイルの生バイト列。
    /// - Returns: `body`（HTTP リクエストボディ）と `contentType`（`Content-Type` ヘッダ値）のタプル。
    public static func singleFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data
    ) -> (body: Data, contentType: String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        let crlf = "\r\n"

        var body = Data()

        // --boundary
        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(crlf)")
        body.append("Content-Type: \(mimeType)\(crlf)")
        body.append(crlf)
        body.append(data)
        body.append(crlf)

        // --boundary--
        body.append("--\(boundary)--\(crlf)")

        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
