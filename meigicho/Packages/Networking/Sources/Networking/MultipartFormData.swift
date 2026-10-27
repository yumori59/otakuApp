import Foundation

/// `PUT /v1/me/avatar` 用の単一ファイルパート multipart/form-data ボディ生成（`api-contract-delta.md` §0.1 / §2）。
///
/// RFC 2046 に従い行区切りは CRLF。境界は `"Boundary-" + UUID().uuidString`。
public enum MultipartFormData {

    /// 単一ファイルパートの body と `Content-Type` ヘッダー値を返す。
    ///
    /// - Parameters:
    ///   - name: フォームフィールド名（契約: `"file"`）
    ///   - filename: `Content-Disposition` の `filename` 属性（サーバーは使わない。任意文字列可）
    ///   - mimeType: パートの `Content-Type`（サーバーはマジックバイトで再判定するため任意値可）
    ///   - data: ファイルバイナリ
    /// - Returns: `(body: Data, contentType: String)`。`contentType` を `Endpoint` の `contentType` に渡す。
    public static func singleFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data
    ) -> (body: Data, contentType: String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        let crlf = "\r\n"

        var body = Data()
        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(crlf)")
        body.append("Content-Type: \(mimeType)\(crlf)")
        body.append(crlf)
        body.append(data)
        body.append(crlf)
        body.append("--\(boundary)--\(crlf)")

        let contentType = "multipart/form-data; boundary=\(boundary)"
        return (body: body, contentType: contentType)
    }
}

// MARK: - Private helper

private extension Data {
    mutating func append(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}
