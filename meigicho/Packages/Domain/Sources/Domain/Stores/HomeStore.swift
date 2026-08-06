import Foundation
import Core

/// `GET /v1/home/summary` のストア。ホームの 3 指標カード用。
@MainActor
@Observable
public final class HomeStore {
    public private(set) var summary: HomeSummary?
    public private(set) var state: LoadState = .idle

    private let repository: (any HomeRepository)?

    public init(repository: (any HomeRepository)? = nil) {
        self.repository = repository
    }

    public func load() async {
        guard let repository else { return }
        state = .loading
        do {
            summary = try await repository.fetchSummary()
            state = .loaded
        } catch {
            state = .failed(Self.appError(from: error))
        }
    }

    public func clear() {
        summary = nil
        state = .idle
    }

    private static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}
