import Foundation

/// API のエラー envelope（`contract-mapping.md` §2.3）。
///
/// `Network` はレスポンスボディをこの型にデコードし、`AppError.from(envelope:)` で変換する。
/// **知識をここ 1 箇所に集めるため、コード→ケースの対応表を Network 側に複製しない。**
public struct APIErrorEnvelope: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String?
    public let details: JSONValue?
    public let requestID: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case details
        case requestID = "request_id"
    }

    public init(code: String, message: String? = nil, details: JSONValue? = nil, requestID: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.requestID = requestID
    }
}

/// アプリ全体で扱うエラー。UI 文言は `userMessage`。
public enum AppError: Error, Equatable, Sendable {
    case validation(message: String?)
    case unauthenticated
    case appleSignInFailed
    case googleSignInFailed
    case credentialsInvalid
    case resetCodeInvalid
    case sessionExpired
    case forbidden
    case planLimitIdentity(limit: Int?, current: Int?)
    case planLimitShare(limit: Int?, current: Int?)
    case planLimitShareWrite(limit: Int?, current: Int?)
    case notFound
    case shareInvalid
    /// `POST /v1/shares/received/redeem` の 403。**この 1 経路でしか返らない**
    /// （他のルートは招待の有無を `.shareInvalid` 404 に潰して存在を confirm しない）。
    case shareNotInvited
    /// 招待先の ACC-ID がサーバーに存在しない（400）。
    /// **`accountIDs` を詰めるのは `RemoteShareRepository` だけ**（`details.unknown_account_ids` を
    /// 読める文脈がそこにしか無い）。汎用マッパーは空配列で返す — `.shareItemConflict` と同じ方針。
    case shareRecipientUnknown(accountIDs: [String])
    case emailAlreadyRegistered
    case conflict
    /// 共有ボードの `rev` 不一致。**格上げは `RemoteSharedBoardRepository` だけが行う**
    /// （汎用マッパーは常に `.conflict` を返す — `contract-mapping.md` §2.3）。
    case shareItemConflict(current: SharedItemSnapshot)
    case rateLimited
    case server
    case unknown(code: String, message: String?)
    case decoding(String)
    case offline
    case timeout
    case transport(URLError)

    /// envelope → `AppError`。**未知の `code` は `.unknown` のまま返し、既知ケースに丸めない**（BE-2 の iOS 版）。
    public static func from(envelope: APIErrorEnvelope) -> AppError {
        let limits = PlanLimitDetails(details: envelope.details)
        switch envelope.code {
        case "VALIDATION_ERROR": return .validation(message: envelope.message)
        case "UNAUTHENTICATED": return .unauthenticated
        case "AUTH_APPLE_INVALID": return .appleSignInFailed
        case "AUTH_GOOGLE_INVALID": return .googleSignInFailed
        case "AUTH_CREDENTIALS_INVALID": return .credentialsInvalid
        case "AUTH_RESET_CODE_INVALID": return .resetCodeInvalid
        case "AUTH_REFRESH_INVALID": return .sessionExpired
        case "FORBIDDEN": return .forbidden
        case "PLAN_LIMIT_IDENTITY": return .planLimitIdentity(limit: limits.limit, current: limits.current)
        case "PLAN_LIMIT_SHARE": return .planLimitShare(limit: limits.limit, current: limits.current)
        case "PLAN_LIMIT_SHARE_WRITE": return .planLimitShareWrite(limit: limits.limit, current: limits.current)
        case "NOT_FOUND": return .notFound
        case "SHARE_INVALID": return .shareInvalid
        case "SHARE_NOT_INVITED": return .shareNotInvited
        // `details.unknown_account_ids` はここでは読まない（形を知るのは RemoteShareRepository だけ）
        case "SHARE_RECIPIENT_UNKNOWN": return .shareRecipientUnknown(accountIDs: [])
        case "EMAIL_ALREADY_REGISTERED": return .emailAlreadyRegistered
        case "CONFLICT": return .conflict
        case "RATE_LIMITED": return .rateLimited
        case "INTERNAL": return .server
        default: return .unknown(code: envelope.code, message: envelope.message)
        }
    }

    public static func from(urlError: URLError) -> AppError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timeout
        default:
            return .transport(urlError)
        }
    }

    /// 認証状態を落とすべきエラーか（T1 のログインゲートが使う）。
    public var isSessionEnding: Bool {
        switch self {
        case .unauthenticated, .sessionExpired: true
        default: false
        }
    }

    /// UI に出す既定文言（`contract-mapping.md` §2.3）。
    /// 文脈で出し分けたい箇所（`forbidden` / `credentialsInvalid` など）は呼び出し側で上書きする。
    public var userMessage: String {
        switch self {
        case .validation(let message):
            #if DEBUG
            if let message, !message.isEmpty { return "入力内容を確認してください（\(message)）" }
            #endif
            return "入力内容を確認してください"
        case .unauthenticated, .sessionExpired:
            return "ログインが必要です"
        case .appleSignInFailed:
            return "Apple ID での確認に失敗しました。もう一度お試しください"
        case .googleSignInFailed:
            return "Google アカウントでの確認に失敗しました。もう一度お試しください"
        case .credentialsInvalid:
            return "メールアドレスまたはパスワードが違います"
        case .resetCodeInvalid:
            return "コードが正しくないか、有効期限が切れています"
        case .forbidden:
            return "この操作は許可されていません"
        case .planLimitIdentity(let limit, _):
            guard let limit else { return "無料プランの上限に達しました" }
            return "無料プランで登録できる名義は \(limit) 件までです"
        case .planLimitShare(let limit, _):
            guard let limit else { return "無料プランの上限に達しました" }
            return "無料プランで作れる共有リンクは \(limit) 本までです"
        case .planLimitShareWrite(let limit, let current):
            guard let limit else { return "編集を許可する共有はプランの上限を超えています" }
            if let current {
                return "編集を許可する共有は \(limit) 公演までです（このツアーは \(current) 公演）"
            }
            return "編集を許可する共有は \(limit) 公演までです"
        case .notFound:
            return "対象が見つかりません。一覧を更新してください"
        case .shareInvalid:
            return "この共有リンクは無効です"
        case .shareNotInvited:
            return "この共有はあなたに共有されていません"
        case .shareRecipientUnknown(let accountIDs):
            guard !accountIDs.isEmpty else { return "見つからないアカウント ID があります" }
            return "見つからないアカウント ID があります: \(accountIDs.joined(separator: "、"))"
        case .emailAlreadyRegistered:
            return "このメールアドレスは既に登録されています。ログインしてください"
        case .conflict:
            return "すでに登録されています。一覧を更新してください"
        case .shareItemConflict:
            return "他の人が先に更新しました。最新の内容に更新しました"
        case .rateLimited:
            return "試行回数が上限に達しました。しばらく待ってからお試しください"
        case .server:
            return "サーバーエラーが発生しました。時間をおいて再試行してください"
        case .unknown(let code, _):
            return "エラーが発生しました（\(code)）"
        case .decoding:
            return "応答を解釈できませんでした"
        case .offline:
            return "オフラインです。通信環境を確認してください"
        case .timeout:
            return "通信がタイムアウトしました。もう一度お試しください"
        case .transport:
            return "通信に失敗しました。もう一度お試しください"
        }
    }
}

/// `PLAN_LIMIT_*` の `details`。**欠落・型不一致でクラッシュさせない**（AC-N-06-T）。
private struct PlanLimitDetails {
    let limit: Int?
    let current: Int?

    init(details: JSONValue?) {
        guard case .object(let object)? = details else {
            limit = nil
            current = nil
            return
        }
        limit = object["limit"]?.intValue
        current = object["current"]?.intValue
    }
}
