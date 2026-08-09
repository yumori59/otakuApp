import Foundation
import Core
import Domain

/// HTTP レスポンスの検証。**認証あり / なしの両クライアントで共有する**。
///
/// エラー envelope → `AppError` の対応表は `Domain.AppError.from(envelope:)` が唯一の正。
/// ここに複製しない（BE がコードを増やしたときの追従漏れを避ける）。
enum ResponseValidator {
    private static let logger = AppLogger(category: "api")

    /// 2xx 以外なら `AppError` を throw する。
    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.decoding("response is not HTTP")
        }
        guard !(200...299).contains(http.statusCode) else { return }

        guard let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) else {
            // envelope でない（プロキシの HTML など）。**本文はログに出さない**
            logger.error(code: "HTTP_\(http.statusCode)", requestID: nil)
            throw AppError.decoding("unexpected error body (status \(http.statusCode))")
        }
        // ログに残すのは code と request_id だけ（message には個人情報が混ざりうる）
        logger.error(code: envelope.code, requestID: envelope.requestID)
        throw AppError.from(envelope: envelope)
    }

    /// 転送エラーを `AppError` に写す。
    static func mapTransportError(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "TRANSPORT", message: nil)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // どの型のデコードに失敗したかだけ残す（値は残さない）
            throw AppError.decoding("failed to decode \(String(describing: type))")
        }
    }
}
