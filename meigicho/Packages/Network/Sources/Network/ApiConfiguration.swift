import Foundation

/// API クライアントの設定（`contract-mapping.md` §1）。
public struct ApiConfiguration: Equatable, Sendable {
    /// 末尾スラッシュ無しの baseURL（`Info.plist` の `API_BASE_URL`）
    public let baseURL: URL
    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval

    public init(baseURL: URL, requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpAdditionalHeaders = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}
