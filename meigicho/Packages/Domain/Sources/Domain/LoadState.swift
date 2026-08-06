import Foundation

/// 一覧の読み込み状態。**「空データ」と「読み込み失敗」を区別する**（E-1）。
public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(AppError)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var error: AppError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
