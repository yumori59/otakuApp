import XCTest

/// D3（`docs/plans/admob-integration/plan.md` §4）の型ガードに加え、実際の View ソースを
/// 走査して `AdSlot` が禁止面に紛れ込んでいないことを検査する（AC-AD-27）。
///
/// `Domain.AdPlacement` が禁止面の case を持たないことは `AdGatekeeperTests` 側で担保する
/// （AC-AD-26）。本テストは「たとえ誤って呼べたとしても」を防ぐ最後の網として、
/// `Features` パッケージをビルド依存に加えずソースファイルを文字列走査する。
final class AdSlotForbiddenScreensTests: XCTestCase {
    /// `docs/plans/admob-integration/requirements.md` F3 の禁止画面。
    /// `Packages/Features/Sources/Features` からの相対パス。
    private static let forbiddenRelativePaths = [
        "Detail/ApplicationDetailView.swift",
        "Forms/AddIdentityView.swift",
        "Forms/AddMembershipView.swift",
        "Forms/AddApplicationView.swift",
        "Forms/ApplicationFormView.swift",
        "Forms/SheetContentView.swift",
        "Share/SharePreviewView.swift",
        "SharedBoard/SharedBoardView.swift",
    ]

    private var featuresSourcesRoot: URL {
        // .../Packages/DesignSystem/Tests/DesignSystemTests/AdSlotForbiddenScreensTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Packages
            .appendingPathComponent("Features/Sources/Features")
    }

    func testAdSlotDoesNotAppearInForbiddenScreens() throws {
        for relativePath in Self.forbiddenRelativePaths {
            let fileURL = featuresSourcesRoot.appendingPathComponent(relativePath)
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                XCTFail("禁止画面ファイルが見つからない（パス前提が崩れていないか確認）: \(fileURL.path)")
                continue
            }
            XCTAssertFalse(
                contents.contains("AdSlot"),
                "\(relativePath) に AdSlot が出現してはいけない（F3 / D3 / AC-AD-27）"
            )
        }
    }
}
