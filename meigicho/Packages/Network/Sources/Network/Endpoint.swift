import Foundation
import Core
import Domain

/// 1 リクエストの組み立て（純粋関数部分）。
///
/// **`/v1` あり / なしを型で表現する**（`contract-mapping.md` §1 / `plan.md` §3.2）。
/// `GET /public/shares/:token` 系は BE 側で global prefix から除外されているため `/v1` を付けてはいけない。
/// 文字列連結で分岐させない。
public struct Endpoint: Equatable, Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public enum Path: Equatable, Sendable {
        /// `baseURL + "/v1" + path`（Bearer 必須の通常経路）
        case versioned(String)
        /// `baseURL + path`（`/public/*`。Bearer を付けない）
        case publicPath(String)

        var isVersioned: Bool {
            if case .versioned = self { return true }
            return false
        }

        func resolved() -> String {
            switch self {
            case .versioned(let path): "/v1" + normalized(path)
            case .publicPath(let path): normalized(path)
            }
        }

        private func normalized(_ path: String) -> String {
            path.hasPrefix("/") ? path : "/" + path
        }
    }

    public let method: Method
    public let path: Path
    public let query: [URLQueryItem]
    public let body: Data?

    public init(method: Method, path: Path, query: [URLQueryItem] = [], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }

    public static func versioned(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> Endpoint {
        Endpoint(method: method, path: .versioned(path), query: query, body: body)
    }

    public static func publicPath(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> Endpoint {
        Endpoint(method: method, path: .publicPath(path), query: query, body: body)
    }

    /// `URLRequest` を組み立てる。
    /// **`Authorization` はここでは付けない**（付けるのは `ApiClient` だけ。`PublicApiClient` は渡さない）。
    public func urlRequest(baseURL: URL, extraHeaders: [String: String]) throws -> URLRequest {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }

        guard var components = URLComponents(string: base + path.resolved()) else {
            throw AppError.decoding("invalid URL for \(path.resolved())")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw AppError.decoding("invalid URL components for \(path.resolved())")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUIDv7.generate().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
