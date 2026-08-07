import SwiftUI
import Domain

/// App 層（`Info.plist` のユニット ID・`DataStore.Reachability`）を `Features` から使うための橋。
///
/// `Features` は `DataStore` / `Network` / SDK を import しない（IOS-5）。広告の表示可否そのものは
/// `Domain.AdsStore` / `AdGatekeeper` が持ち、**App 層にしか無い値だけ**をここで注入する:
///
/// - `unitIDs`: AdMob のユニット ID（`Info.plist` の `ADMOB_UNIT_*`）。未設定なら空文字 → `AdSlot` は高さ 0
/// - `refreshOnline`: 到達性を測り直して `AdsStore.setOnline(_:)` に反映する（F4-4 / AC-AD-40）
///
/// 既存パターン踏襲: `Features/Home/SyncActionBridge.swift`
public struct AdsBridge: @unchecked Sendable {
    /// 面ごとの AdMob ユニット ID。未設定の面は空文字として扱う。
    public var unitIDs: [AdPlacement: String]
    /// 到達性を測り直して `AdsStore` に書き戻す。既定は何もしない（プレビュー・UI テスト）。
    public var refreshOnline: @Sendable () async -> Void

    public init(
        unitIDs: [AdPlacement: String] = [:],
        refreshOnline: @escaping @Sendable () async -> Void = {}
    ) {
        self.unitIDs = unitIDs
        self.refreshOnline = refreshOnline
    }

    /// 未設定の面は空文字を返す。`AdSlot` は空文字を「枠を出さない」として扱う（E1 / AC-AD-36）。
    public func adUnitID(for placement: AdPlacement) -> String {
        unitIDs[placement] ?? ""
    }

    public static let noop = AdsBridge()
}

private struct AdsBridgeKey: EnvironmentKey {
    static let defaultValue = AdsBridge.noop
}

extension EnvironmentValues {
    public var adsBridge: AdsBridge {
        get { self[AdsBridgeKey.self] }
        set { self[AdsBridgeKey.self] = newValue }
    }
}
