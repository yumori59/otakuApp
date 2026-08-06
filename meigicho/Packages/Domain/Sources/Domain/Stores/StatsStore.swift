import Foundation
import Core

/// `GET /v1/stats/identities` のストア。名義一覧の当選数などに使う。
@MainActor
@Observable
public final class StatsStore {
    public private(set) var snapshot: IdentityStatsSnapshot?
    public private(set) var state: LoadState = .idle

    private let repository: (any StatsRepository)?

    public init(repository: (any StatsRepository)? = nil) {
        self.repository = repository
    }

    public func load() async {
        guard let repository else { return }
        state = .loading
        do {
            snapshot = try await repository.fetchIdentityStats()
            state = .loaded
        } catch {
            state = .failed(Self.appError(from: error))
        }
    }

    public func clear() {
        snapshot = nil
        state = .idle
    }

    /// API 未取得時はローカル集計へフォールバック（home/summary と同型）。
    public func winCount(for identityID: UUID, fallback: Int) -> Int {
        snapshot?.item(for: identityID)?.wonCount ?? fallback
    }

    /// API 取得済みなら API 値で上書きし、未知の名義は fallback を残す。
    public func winCounts(fallback: [UUID: Int]) -> [UUID: Int] {
        guard let snapshot, state == .loaded else { return fallback }
        var result = fallback
        for (id, count) in snapshot.winCounts() {
            result[id] = count
        }
        return result
    }

    private static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}
