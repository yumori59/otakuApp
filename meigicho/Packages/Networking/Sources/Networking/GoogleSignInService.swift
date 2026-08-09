import Foundation
import AuthenticationServices
import Core
import Domain

#if canImport(UIKit)
import UIKit
#endif

/// Google サインイン（`plan.md` §7.2.1 の決定事項）。
///
/// **`ASWebAuthenticationSession` + PKCE の自前実装。第三者 SDK を追加しない。**
/// 差し替えが必要になったとき影響をこの 1 ファイルに閉じるため、
/// 認可 URL の組み立て・コールバック解析・トークン交換をすべてここに置く（R8）。
///
/// 得たいのは **一度きりの `id_token`** だけで、セッション維持は自前 JWT が担う。
public struct GoogleSignInService: GoogleSignInProviding {
    private let clientID: String
    private let tokenEndpoint: URL
    private let session: URLSession

    public init(
        clientID: String,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        session: URLSession = .shared
    ) {
        self.clientID = clientID
        self.tokenEndpoint = tokenEndpoint
        self.session = session
    }

    /// `Info.plist` の `GOOGLE_IOS_CLIENT_ID` から組み立てる。**未設定なら nil**（ボタンは出すが実行できない）。
    public static func makeFromBundle(_ bundle: Bundle = .main) -> GoogleSignInService? {
        let raw = (bundle.object(forInfoDictionaryKey: "GOOGLE_IOS_CLIENT_ID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, GoogleAuthorizationRequest.reversedClientID(from: raw) != nil else { return nil }
        return GoogleSignInService(clientID: raw)
    }

    /// 認可 → コード交換 → `id_token`。
    /// **ユーザーキャンセルは nil を返す**（エラー表示しない = E-14 / AC-GG-04-M）。
    public func signIn() async throws -> GoogleIdentity? {
        guard let request = GoogleAuthorizationRequest(clientID: clientID) else {
            throw AppError.googleSignInFailed
        }

        let outcome = await Self.presentWebAuth(
            url: request.authorizationURL,
            callbackScheme: request.callbackScheme
        )

        let callbackURL: URL
        switch outcome {
        case .cancelled:
            return nil
        case .failed(let error):
            throw error
        case .url(let url):
            callbackURL = url
        }

        // `state` 不一致は拒否する（AC-GG-02-T）
        switch try GoogleAuthorizationRequest.parseCallback(callbackURL, expectedState: request.state) {
        case .cancelled:
            return nil
        case .code(let code):
            let idToken = try await exchange(code: code, request: request)
            // **`id_token` は加工しない**。nonce は認可リクエストに載せたのと同じ文字列（AC-GG-07 / A2）
            return GoogleIdentity(idToken: idToken, nonce: request.nonce)
        }
    }

    // MARK: - トークン交換

    /// `POST https://oauth2.googleapis.com/token`。
    /// **`application/x-www-form-urlencoded` なので `ApiClient` を通さない**（JSON 前提のため）。
    /// iOS クライアントに `client_secret` は無い（PKCE の `code_verifier` が代わり）。
    private func exchange(code: String, request: GoogleAuthorizationRequest) async throws -> String {
        var urlRequest = URLRequest(url: tokenEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Data(
            GoogleAuthorizationRequest.formURLEncoded([
                ("code", code),
                ("client_id", request.clientID),
                ("code_verifier", request.codeVerifier),
                ("redirect_uri", request.redirectURI),
                ("grant_type", "authorization_code"),
            ]).utf8
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ResponseValidator.mapTransportError(error)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // Google のエラー本文は記録しない（token / code が混ざりうる）
            AppLogger(category: "auth").error(code: "GOOGLE_TOKEN_EXCHANGE", requestID: nil)
            throw AppError.googleSignInFailed
        }
        guard let token = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data), !token.idToken.isEmpty else {
            throw AppError.googleSignInFailed
        }
        return token.idToken
    }

    // MARK: - ブラウザ表示

    enum WebAuthOutcome: Sendable {
        case url(URL)
        case cancelled
        case failed(AppError)
    }

    @MainActor
    static func presentWebAuth(url: URL, callbackScheme: String) async -> WebAuthOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<WebAuthOutcome, Never>) in
            let anchorProvider = WebAuthPresentationAnchorProvider()
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                // provider をここで捕まえて、セッション終了まで生かす（弱参照のため）
                _ = anchorProvider
                if let callbackURL {
                    continuation.resume(returning: .url(callbackURL))
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .cancelled)
                    return
                }
                continuation.resume(returning: .failed(.googleSignInFailed))
            }
            session.presentationContextProvider = anchorProvider
            // 既存の Google セッションを使い回せるようにする（毎回のパスワード入力を避ける）
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(returning: .failed(.googleSignInFailed))
            }
        }
    }
}

/// `id_token` 以外は使わない（access_token / refresh_token を保持しない）。
struct GoogleTokenResponse: Decodable, Sendable {
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

@MainActor
private final class WebAuthPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}

// MARK: - 純関数部分（`swift test` で検証する）

/// 1 回の認可リクエスト分のパラメータ。**組み立ては純関数**（AC-GG-01-T）。
public struct GoogleAuthorizationRequest: Equatable, Sendable {
    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let scope = "openid email profile"

    public let clientID: String
    /// `<reversed client id>:/oauth2redirect`
    public let redirectURI: String
    /// `ASWebAuthenticationSession(callbackURLScheme:)` に渡す値（= reversed client id）
    public let callbackScheme: String
    public let codeVerifier: String
    public let codeChallenge: String
    /// BE にそのまま送る nonce（sha256 しない — A2）
    public let nonce: String
    public let state: String

    /// テスト用の直接指定。
    public init?(clientID: String, codeVerifier: String, nonce: String, state: String) {
        guard let reversed = Self.reversedClientID(from: clientID) else { return nil }
        self.clientID = clientID
        self.callbackScheme = reversed
        self.redirectURI = "\(reversed):/oauth2redirect"
        self.codeVerifier = codeVerifier
        self.codeChallenge = PKCE.challenge(for: codeVerifier)
        self.nonce = nonce
        self.state = state
    }

    /// 実行時用。`codeVerifier` / `nonce` / `state` を毎回新しく作る。
    public init?(clientID: String) {
        self.init(
            clientID: clientID,
            codeVerifier: PKCE.generateCodeVerifier(),
            nonce: Nonce.generate(),
            state: Nonce.generate(byteCount: 16)
        )
    }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
    public static func reversedClientID(from clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let identifier = String(clientID.dropLast(suffix.count))
        guard !identifier.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(identifier)"
    }

    public var authorizationURL: URL {
        var components = URLComponents(string: Self.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public enum CallbackResult: Equatable, Sendable {
        case code(String)
        /// `error=access_denied`。**ユーザーキャンセル扱い**でエラー表示しない（E-14）
        case cancelled
    }

    /// コールバック URL の解析。**`state` 不一致は拒否する**（AC-GG-02-T）。
    public static func parseCallback(_ url: URL, expectedState: String) throws -> CallbackResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if value("error") == "access_denied" {
            return .cancelled
        }
        guard value("error") == nil else {
            throw AppError.googleSignInFailed
        }
        guard let state = value("state"), state == expectedState else {
            throw AppError.googleSignInFailed
        }
        guard let code = value("code"), !code.isEmpty else {
            throw AppError.googleSignInFailed
        }
        return .code(code)
    }

    /// `application/x-www-form-urlencoded`。`+` を含む値を壊さないため自前でエンコードする。
    static func formURLEncoded(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}
