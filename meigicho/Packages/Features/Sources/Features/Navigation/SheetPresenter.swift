import Foundation

/// シート表示の入れ物。**他の Observable ストアと同じく `@MainActor`**
/// （`AuthStore` / `ProfileStore` / `IdentityStore` などと平仄を合わせ、`@unchecked Sendable` を使わない）。
@MainActor
@Observable
public final class SheetPresenter {
    public var activeSheet: AppSheet?

    public init() {}
}
