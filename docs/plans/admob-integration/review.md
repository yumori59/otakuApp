# review — admob-integration Stage 1（バナー広告のみ）

対象: `main...work/admob-integration`（`7db0ed2` T0 / `c6dd11c` T5 / `bd5aed6` T9 / `2a85534` T8 / `afa9586` T10）
レビュー実施: code-reviewer（別セッション）。**重大 3 件を検出し、本レビュー内で修正・再検証済み**（修正コミット `c17bc40`）。

スコープ外（指摘対象外）: Stage 2（ネイティブ / リワード / SSV / PaywallView 連携）、AdMob 実 ID 未取得、起動 TTI 実測（AC-AD-37）、ATT / UMP の実装（意図的に不採用）。

---

## レビュー結果サマリ

- 重大: 3 件（すべて修正済み → 再レビューで重大 0 件）
- 中: 4 件（うち 2 件を修正、2 件は残課題として記載）
- 軽微 / 提案: 6 件

---

## 重大 (Must Fix) — 修正済み

### C1. `ADMOB_APP_ID: ""` で**アプリが起動直後にクラッシュする**（AC-AD-36 / N6 の直接違反）

- 検出箇所: `meigicho/project.yml:53`（修正前 `ADMOB_APP_ID: ""`）→ `meigicho/App/Info.plist:56` の `GADApplicationIdentifier`
- 実測: シミュレータ（iPhone 17 Pro / iOS 26.x）で起動 → `SIGABRT`。
  クラッシュレポート `~/Library/Logs/DiagnosticReports/Meigicho-2026-08-07-090053.ips` の
  `lastExceptionBacktrace` が `GADApplicationVerifyPublisherInitializedCorrectly` → `objc_exception_throw`。
- 原因: GoogleMobileAds SDK は**リンクされているだけで**起動時にディスパッチキュー上で
  `GADApplicationIdentifier` を検証し、空文字 / キー欠落なら `NSException` を投げる。
  `GADMobileAds.start` を呼ぶかどうかとは無関係なので、`AdRendererFactory` の
  「空なら `DisabledAdRenderer` を返す」ガード（`App/Ads/AdRendererFactory.swift`）では防げない。
- 影響: **現ブランチの Debug / Release 既定設定で 100% 起動不能**。T9 / T10 は `xcodebuild build` のみで
  完了判定しており、実行時検証（`05-harness.md` の「API をまたぐ変更は手動確認手順」）が抜けていた。
- 修正:
  - `meigicho/project.yml:53` — `ADMOB_APP_ID` の既定値を Google 公式サンプルアプリ ID
    `ca-app-pub-3940256099942544~1458002511` に変更し、「空にしてはいけない理由」をコメントで固定。
  - 「広告を実際に出すか」の判定を **app ID ではなく `ADMOB_UNIT_*` の有無**へ移した:
    `App/Ads/AdRendererFactory.swift`（`make(hasConfiguredUnitIDs:)`）/
    `App/AppEnvironment.swift:130-137`。ユニット ID が 0 件なら `DisabledAdRenderer` を返し、
    `AdsInitializer.start()`（= SDK 初期化・ネットワーク）は走らない。F1-6 / N6 の意図は維持。
  - `meigicho/Meigicho.xcodeproj/project.pbxproj` を `xcodegen generate` で再生成
    （**project.yml だけ直しても pbxproj の `ADMOB_APP_ID = ""` が残りクラッシュし続ける**）。
- 再検証: シミュレータへ install → launch → 15 秒後もプロセス生存を確認（クラッシュ再現なし）。

### C2. `AdSlot` の固定高 `GeometryReader` が後続コンテンツに重なる（E18 違反）

- 検出箇所: 修正前 `DesignSystem/Ads/AdSlot.swift:35-43` — `GeometryReader { ... }.frame(height: 100)`
- 問題: `GeometryReader` は子をクリップせず、子の理想サイズも尊重しない。
  `AdCardChrome` は padding 14×2 +「広告」ラベル +spacing で約 56pt、
  インライン・アダプティブバナー本体は画面高の最大 15%（iPhone で ~100〜125pt）なので、
  合計 ~160〜180pt が高さ 100pt の枠からはみ出して**下の要素に重なって描画される**。
  とくに `ApplicationListView.swift:196-201` のツアー表（`tour-group` 間の挿入）では
  次のツアーグループに直接重なる。
- `plan.md` §3 E18 は「プレースホルダ高さは固定だが `minHeight` で扱い、はみ出さないこと」と
  明記しており、実装が計画と食い違っていた。
- 修正: `DesignSystem/Ads/AdSlot.swift` を書き直し、
  `GeometryReader` は `background` に置いて**幅の計測だけ**に使い、
  高さは `.frame(maxWidth: .infinity, minHeight: placeholderHeight, alignment: .top)` で下限として確保する。
  幅が確定するまでは枠だけを描く（AC-AD-34 のリストジャンプ防止は維持）。

### C3. no-fill（広告非配信）時に「広告」ラベル付きの**空カードが残る**（F4-4 / F5-6 / `docs/07:448` 違反）

- 検出箇所: 修正前 `App/Ads/GoogleMobileAdsRenderer.swift:44-57` — `GADBannerView.delegate` を設定しておらず、
  `bannerView(_:didFailToReceiveAdWithError:)` を扱っていない。
  `AdSlot` の `didFailToLoad` は「`bannerView(...)` が `nil` を返した」＝ユニット ID 空 / 幅 0 の
  ときしか立たず、**実際のロード失敗・no-fill を検知できない**。
- 影響: 実 ID 投入後は fill rate < 100% が常態なので、枠線 + 「広告」ラベルだけの
  100pt の空カードが日常的に残る。F4-4「空枠を残さない」の明文違反。
- 修正:
  - `DesignSystem/Ads/AdRenderer.swift` — `bannerView(adUnitID:width:onFailure:)` に失敗通知を追加。
  - `App/Ads/GoogleMobileAdsRenderer.swift` — `Coordinator: NSObject, GADBannerViewDelegate` を追加し
    `didFailToReceiveAdWithError` で `onFailure()`。SDK 型は `#if canImport(GoogleMobileAds)` の中に封じたまま。
  - `App/Ads/DisabledAdRenderer.swift` — シグネチャ追従。
  - `DesignSystem/Ads/AdSlot.swift` — `onFailure` で `didFailToLoad = true` → 枠ごと高さ 0。

---

## 中 (Should Fix)

### M1.〔修正済み〕表示中の広告枠が **Plus 化 / ステータス変更 / オフラインで畳まれない**（F4-5 / F4-6）

- 検出箇所: 修正前 `Features/Ads/PlacementAdSlot.swift:754-758` — ラッチ中は `adsStore.isOnline` しか見ていない。
- 問題: ツアー表（`ApplicationsTab`）は**広告許可面でありながら status-changer が同居する**唯一の画面。
  `ApplicationListView.swift:442` でステータスを叩くと `recordStatusChange()` は記録されるが、
  すでに表示中のバナーは畳まれないため、**「当落が動いた瞬間」に広告が画面に出たまま**になる。
  F4-5 の 60 秒クールダウンは F3-1（status-changer の隣に広告を出さない）を担保するための仕組みなので、
  その最重要ケースで効いていなかった。Plus へアップグレードした直後（F4-6）も同様に消えない。
- ラッチ設計自体は妥当（`recordImpression` により F4-1 / F4-3 が自己反転して表示直後に消える問題は実在する）。
  修正はラッチを外すのではなく、**自分が消費した 2 条件だけを除いた再判定**を足す形にした。
- 修正:
  - `Domain/Ads/AdGatekeeper.swift` — `shouldRemainVisible(_:input:)` を追加
    （F4-1 セッション上限と F4-3 同一面連続のみ除外し、F4-2 / F4-4 / F4-5 / F4-6 は表示中も評価）。
  - `Domain/Stores/AdsStore.swift` — `shouldRemainVisible(_:)` を公開し、`Input` 組み立てを `currentInput()` に集約。
  - `Features/Ads/PlacementAdSlot.swift` — ラッチ中は `shouldRemainVisible` で毎回判定。
  - 回帰テスト 5 本を `DomainTests/AdGatekeeperTests.swift` に追加（AC-AD-39 の補強）。

### M2.〔修正済み〕`MainTabView` のプレビューが `AdsStore` 未注入でクラッシュする

- 検出箇所: `Features/Navigation/MainTabView.swift:33-70`。
  `IdentitiesTab` → `PlacementAdSlot` と `TourGroupView` が `@Environment(AdsStore.self)`（非 Optional）を
  要求するようになったが、2 つの `#Preview` は `AdsStore` を注入していない。
- 実行時ゲート（`xcodebuild build`）では検出できない。本リポジトリはプレビューを維持している
  （`OpenSharedBoardView.swift:87` / `AccountDeleteView.swift:256` など）ため平仄として問題。
- 修正: 両プレビューに `.environment(AdsStore())` を追加（`MainTabView.swift:41, 63`）。

### M3.〔残課題〕`PlacementAdSlot` の 5 秒 × 24 回ポーリングは動くが、必要以上に回り続ける

- `Features/Ads/PlacementAdSlot.swift:727-736`。キャンセル処理（`Task.isCancelled` の二重チェック、
  `try? await Task.sleep`）は正しく、`.task` は画面離脱で自動キャンセルされるためリークも二重起動も無い。
  `AdsBridge.refreshOnline` の実体は `Reachability.refresh()`（`DataStore/Sync/Reachability.swift:18`）で
  `SCNetworkReachabilityGetFlags` のみ。ネットワーク I/O が無いので電力影響は小さい。
- ただし **枠が表示済みになった後もクールダウン監視のために 120 秒回り続ける**、
  かつ画面上の枠ごとに独立したループが走る。将来ネイティブ広告（Stage 2）で枠数が増えると効率が悪い。
- 提案: クールダウンが両方明け、かつ `isVisible` が確定したら `break` する。
  または `AdsStore` 側に 1 本だけタイマーを持たせて `@Observable` の変更で駆動する。

### M4.〔残課題〕インプレッションを「表示決定時」に数えており、実配信を数えていない

- `Features/Ads/PlacementAdSlot.swift:760-762` — `isVisible = true` と同時に `recordImpression`。
  C3 の修正で no-fill 時は枠が畳まれるようになったが、**セッション 3 枚上限（F4-1）は消費済み**のまま。
- 保守的側（広告を出しすぎない）に倒れているので Stage 1 では許容。
  Stage 2 で収益を見る段階になったら「配信成功時に数える」へ寄せるか判断すること。

---

## 軽微 / 提案

1. **UMP フレームワークが推移的にリンクされる** — `Package.resolved` に
   `swift-package-manager-google-user-messaging-platform 2.7.0`、ビルド成果物の
   `Meigicho.app/Frameworks/` に `UserMessagingPlatform.framework` が入る。
   `docs/08 §2.8`（UMP を入れない）は「同意画面を出さない」という意味では守られている
   （呼び出しコードは無い）が、バイナリサイズと App Store の申告確認のため認識しておくこと。
2. **`AdPlacement.homeBottom` / `.applicationsInline` が Stage 1 では未使用**（`Domain/Ads/AdPlacement.swift`）。
   Stage 2 で使う前提が `plan.md` に書かれているので IOS-1 のデッドコードには当たらないが、
   Stage 2 が長期に延びるなら一旦削る判断もある。
3. **`AdSlot.placeholderHeight = 100` の根拠コメントが実態と合っていなかった**
   （「一般的なバナー高さ ~50〜100pt を上回らない」は誤り。アダプティブバナーは画面高の 15% まで伸びる）。
   C2 の修正でコメントも下限扱いに書き換え済み。
4. **`NotificationCenter` オブザーバを解除していない**（`App/AppEnvironment.swift:157-181`）。
   `AppEnvironment` はアプリ生存期間中ずっと生きるので実害は無いが、`deinit` での `removeObserver` があると安全。
5. **`AdGatekeeperTests.testACAD27_...`（Domain）と `AdSlotForbiddenScreensTests`（DesignSystem）が同内容**。
   `plan.md` の AC-AD-27 を 2 パッケージから守る意図は理解できるが、
   禁止画面リストが 2 箇所にあるので片方だけ更新される事故に注意。
6. **`DesignSystem/Package.swift` に `.macOS(.v14)` を追加**した点は `swift test` を回すためで妥当
   （`Domain` / `Core` / `Network` と同じ構成）。依存は `Core` のみのままで、`Domain` / `App` への逆流は無い。

---

## 良かった点

- **D3 の型ガードが実際に機能している**。`AdPlacement`（`Domain/Ads/AdPlacement.swift`）は許可 5 面のみで、
  禁止面は `PlacementAdSlot` を構築する引数自体が作れない。加えて Domain / DesignSystem 双方の
  ソース走査テストが禁止 8 画面に `AdSlot` 文字列が無いことを機械検証しており、
  `PlacementAdSlot` も部分文字列で引っかかるので網が二重に効いている。
  T10 が `ApplicationDetailView.swift:92-99` にクールダウン記録を足したときも、
  コメント・実コードともに `AdSlot` を含まない書き方に揃えられている（テストで確認済み）。
- **IOS-5 を守れている**。`Features/Ads/AdsBridge.swift` / `PlacementAdSlot.swift` は
  `SwiftUI` / `DesignSystem` / `Domain` しか import しておらず、`DataStore` / `Network` / `GoogleMobileAds` は
  一切参照していない。SDK 型は `App/Ads/*.swift` の `#if canImport(GoogleMobileAds)` に封じられている。
- **ATT / NPA 準拠**。ビルド成果物の Info.plist に `NSUserTrackingUsageDescription` も
  `SKAdNetworkItems` も存在しないことを実測で確認（`docs/08 §2.8` / F1-5 / N7）。
  NPA は `GADExtras(npa=1)`（リクエスト単位）と `publisherPrivacyPersonalizationState = .disabled`
  （SDK 全体）の二重で担保されている。
- **F4-5 の配線漏れが無い**。`updateApplicationStatus` の呼び出し元は
  `ApplicationDetailView.swift:99` と `ApplicationListView.swift:445` の 2 箇所のみ（リポジトリ全 grep で確認）。
  両方に `recordStatusChange()` が入っている。
- **既存パターンとの平仄が良い**。`AdsBridge` は `Features/Home/SyncActionBridge.swift` と同型
  （`@unchecked Sendable` + `EnvironmentKey` + `.noop`）、`AdRendererFactory` / `DisabledAdRenderer` は
  `App/Purchases/PurchasesServiceFactory.swift` / `DisabledPurchasesService.swift` と同型。
- **`AdGatekeeper` を SDK 非依存の純粋型に切り出した判断**（F4-7 / `01-aidlc.md`）により、
  F4 の 6 条件が XCTest で検証できている。今回の M1 修正もテストだけで回帰を固定できた。
- `AppEnvironment` の広告配線は既存の `SyncEngine` / 認証状態監視と独立しており、衝突は無い。
  `MeigichoApp.swift` の `scenePhase` 監視（ログイン時のみ同期）とは別に
  `UIApplication.didEnterBackground` / `willEnterForeground` で完結させた判断は妥当。

---

## 検証結果（修正後）

| コマンド | 結果 |
|---|---|
| `cd meigicho/Packages/Domain && swift test` | 183 tests / 0 failures（追加 5 本を含む） |
| `cd meigicho/Packages/DesignSystem && swift test` | 1 test / 0 failures |
| `cd meigicho/Packages/Core && swift test` | 17 tests / 0 failures |
| `cd meigicho/Packages/Network && swift test` | 148 tests / 0 failures |
| `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` | **BUILD SUCCEEDED** |
| シミュレータ install → launch（iPhone 17 Pro） | **クラッシュせず起動を維持**（C1 の再現が消えたことを確認） |

## 残る手動確認（実 ID 取得後）

1. 実ユニット ID を `ADMOB_UNIT_*` に入れ、名義一覧 / 名義詳細 / ツアー表の 3 面でバナーが出ること（AC-AD-32）。
2. ツアー表でステータスを叩き、表示中のバナーが**その場で消える**こと（M1 の修正確認 / AC-AD-39）。
3. no-fill を意図的に起こし、空カードが残らないこと（C3 の修正確認 / F4-4）。
4. Dynamic Type 最大で広告カードが後続に重ならないこと（C2 の修正確認 / E18）。
5. 起動 TTI p95 < 2 秒（AC-AD-37。SDK 初期化はユニット ID 未設定なら走らないため、実 ID 投入後に計測すること）。

---

# review — admob-integration Stage 2（ネイティブ広告のみ）

対象: `main...work/admob-native`（`d8e8104` ネイティブカード + Renderer / `6de58f8` ホーム・申込一覧への配線）
レビュー実施: code-reviewer（別セッション）。**重大 1 件を検出し、本レビュー内で修正・再検証済み**（修正コミットは本節末尾）。

スコープ外（指摘対象外）: リワード広告・SSV・`PaywallView` 連携、AdMob 実アカウントでの実配信検証、起動 TTI 実測（AC-AD-37）。

## レビュー結果サマリ

- 重大: 1 件（修正済み → 再レビューで重大 0 件）
- 中: 3 件（うち 2 件を修正、1 件は仕様判断待ちとして記載）
- 軽微 / 提案: 4 件

---

## 重大 (Must Fix) — 修正済み

### N-C1. ネイティブ広告カードが枠（98pt）をはみ出して**後続コンテンツに重なる** — IOS-9 と同型の再発（E18 / F5-6 / AC-AD-34 違反）

- 検出箇所: 修正前 `DesignSystem/Ads/NativeAdSlot.swift:39-41`（`.frame(maxWidth:.infinity, minHeight: placeholderHeight, alignment: .top)`）
  + `App/Ads/GoogleMobileAdsRenderer.swift` の `NativeAdRepresentable`（`sizeThatFits` 未実装）
- 原因: `UIViewRepresentable` の実寸は SwiftUI が `sizeThatFits` で 1 度測るだけ。
  その測定は **`makeUIView` 直後（`GADNativeAdView` が空）** に走るので高さ 0 と判定される。
  広告が非同期で届いて `UIHostingController.view` を貼っても、**SwiftUI 側のレイアウトパスは走り直さない**。
  結果、枠は `minHeight` の 98pt のまま固定され、実カードだけが UIKit 側で大きく描かれる。
  Stage 1 の C2（`GeometryReader` 固定高）と症状は同じだが原因が違うため、`minHeight` 化だけでは防げていなかった。
- **実測（推測ではない）**: 同構造の最小ハーネス（`UIViewRepresentable` + 1 秒後に `UIHostingController` を
  4 辺ピンで addSubview + 外側 `.frame(minHeight: 98)`）を iPhone 17 Pro シミュレータで実行し、
  ① 枠は 98pt のまま伸びない ② 本文 3 行が 1 行に潰れる ③ CTA ボタンの枠線が直後の要素に重なる、
  を確認。Dynamic Type 最大では「広告」ラベルが**上の要素にも**重なった。
  `AdNativeCard` の想定実寸は「広告」ラベル 22 + 見出し 2 行 40 + 本文 3 行 51 + CTA 34 + padding 28 ≒ **180pt** で、
  98pt の枠に対して 2 倍近い。実 ID 投入後は常態的に発生する。
- 修正:
  - `DesignSystem/Ads/AdRenderer.swift` — `nativeAdView(adUnitID:onFailure:onHeightChange:)` に実寸通知を追加。
  - `App/Ads/GoogleMobileAdsRenderer.swift` — `Coordinator.remeasure()` で
    `UIHostingController.sizeThatFits(in:)` により実寸を測り、次ランループで通知
    （`updateUIView` 経由でも呼ばれるため、レイアウトパス中の `@State` 書き換えを避ける）。
    `updateUIView` からも測り直すので、幅変化（回転 / Split View）にも追従する。
  - `DesignSystem/Ads/NativeAdSlot.swift` — `@State measuredHeight` を持ち
    `.frame(height: max(placeholderHeight, measuredHeight))` で高さを確定。
    ロード完了までは 98pt を確保するのでリストは飛ばない（AC-AD-34 は維持）。
    測定が間に合わない 1 フレームの保険として `.clipped()` を追加。
  - `App/Ads/DisabledAdRenderer.swift` — シグネチャ追従。
- 再検証: 同ハーネスに修正後の構造を実装して再実行 → 見出し 2 行 + 本文 3 行 + CTA が
  すべて表示され、枠が実寸まで伸び、直後の要素と重ならないことを確認。

---

## 中 (Should Fix)

### N-M1.〔修正済み〕同一ビューを 4 つのアセットプロパティへ重複登録している（クリック重複計上のリスク）

- 検出箇所: 修正前 `App/Ads/GoogleMobileAdsRenderer.swift` — `headlineView` / `bodyView` /
  `iconView` / `callToActionView` にすべて同じ `hosting.view` を代入していた。
- 問題: `GADNativeAdView` は `nativeAd` 設定時に**登録された各アセットビューへタップ認識を付ける**。
  同一ビューを 4 回登録すると認識が 4 本重なり、1 タップが複数クリックとして計上されうる
  （AdMob の無効トラフィック判定に触れるリスク）。また `nativeAd.icon != nil` でも
  `icon.image == nil` なら画像を描画していないのに `iconView` を登録することになる。
- 修正: カード全面を覆う**透明ビュー 1 枚**を作り、必須アセットである `headlineView`
  としてのみ登録する（カード全体がクリック領域という挙動は同じ、登録は 1 本）。
  `AdNativeCard` 側は従来どおりタップ処理を持たない（CTA は `allowsHitTesting(false)`）。
- **残る手動確認**: 実ユニット ID でクリックが 1 回だけ計上されること・遷移が起きることは
  AdMob 管理画面（テスト広告のクリックレポート）で確認が必要。SDK 契約の性質上コードだけでは閉じない。

### N-M2.〔修正済み〕`UIHostingController` を VC 階層に入れずに `view` だけ貼っていた

- 検出箇所: 修正前 `App/Ads/GoogleMobileAdsRenderer.swift`（`addSubview` のみ、`addChild` なし）。
- Coordinator が強参照しているので即座の解放は起きないが、VC コンテインメント無しの
  `UIHostingController` はトレイト（Dynamic Type / ダークモード）とライフサイクルの伝播が
  保証されない。既存の `RevenueCatPurchasesService` 等に前例は無く、UIKit の標準手順から外れている。
- 修正: `addChild` / `didMove(toParent:)` で親に入れ、`dismantleUIView` で
  `willMove(toParent: nil)` → `removeFromParent` を行う後始末を追加。

### N-M3.〔仕様判断が必要・未修正〕F2-3「1 画面 2 枚」は**現行の F4-3 実装では永久に達成できない**

- `Domain/Ads/AdInlineSlots.swift` は 5 件目・15 件目の後に 2 枠を返し、
  `ApplicationListView.swift:170-176` が 2 箇所に `PlacementAdSlot(.applicationsInline)` を置く。
- しかし `AdGatekeeper.shouldShow`（`Domain/Ads/AdGatekeeper.swift:76`）は F4-3 を
  `lastShownPlacement == placement` で表す。2 枠とも `placement` が `.applicationsInline` なので
  **1 枚目がインプレッションを記録した時点で 2 枚目は恒久的に false** になる。
  さらに F4-1（セッション 3 枚）も併走する。
- 結果、`AdInlineSlots.maxPerScreen = 2` と `AdInlineSlotsTests` の「2 枚目 = index 14」は
  **実行時に到達しない挙動をテストしている**（テストが通ることが動作保証にならない）。
  枠が出ないだけで空隙は残らない（`padding` は空の条件ビューには適用されないことを実測で確認済み）ので実害は「収益機会の損失」に留まる。
- 判断: **Domain を今この場で変えない**。F4-3 の「同一画面で連続 2 枚を出さない」を
  「隣接して出さない」と読み替えるのが自然だが、それは Stage 1 で受け入れ済みの
  AC-AD-25（`plan.md` §8.2）を書き換えることになり、レビュアーの独断で変えるべきではない。
  暫定として `AdInlineSlots` の doc comment に相互作用を明記した。

**決定（2026-08-07・ユーザー承認）**: **1 枚のみ許容**。F4-3（同一 placement 連続表示禁止）を
そのまま維持し、`docs/07-monetization.md` §7.2 の「申込一覧 1 画面あたり 2 枚」は**上限であって
最低保証ではない**と解釈する。広告疲れ防止を収益機会より優先する。Domain（`AdGatekeeper`）は
変更しない。`AdInlineSlots.maxPerScreen = 2` は将来 F4-3 の意味を変える判断をしたときのための
上限値として維持し、コードの追加変更は行わない。
- 推奨: `requirements.md` F4-3 / AC-AD-25 を「同一 placement の**連続する 2 枠**を禁止（間に
  コンテンツが挟まれば可）」へ改訂し、`AdGatekeeper` に「直前 1 枚と隣接しているか」を
  渡す形にする。仕様判断なので planner / ユーザーの決定が要る。

---

## 軽微 / 提案

1. `NativeAdSlot.placeholderHeight = 98` の内訳コメント（見出し / 本文 2 行想定）は
   実カードの想定実寸 ≒ 180pt と乖離している。N-C1 の修正で高さは実測値に置き換わるため
   実害は無いが、初期表示のちらつきを減らすなら 140 前後へ寄せる余地がある。
2. `AdSlotForbiddenScreensTests`（`DesignSystem/Tests/.../AdSlotForbiddenScreensTests.swift`）は
   文字列 `AdSlot` の走査なので `NativeAdSlot` / `PlacementAdSlot` も部分一致で捕捉できる
   （実際に禁止 8 画面で 0 ヒットを確認）。ただし `AdNativeCard` 単体を直接置いた場合は
   捕捉できない。走査語を `AdSlot` / `AdNativeCard` の 2 語にすると網が閉じる。
3. `AdInlineSlots.shouldInsertAd` は行ごとに `adPositions` を再計算する（O(n) × n）。
   申込件数の規模では無視できるが、`ForEach` の外で 1 度だけ計算して `Set` に持つ方が素直。
4. `GADAdLoader` は `Coordinator` が強参照し、`delegate` は SDK 側で weak。
   `adView` は `weak`、`GADNativeAd` は `GADNativeAdView.nativeAd`（strong）が保持。
   **循環参照は無い**ことを確認済み。`dismantleUIView` の追加で画面離脱時の解放も明示的になった。

---

## 良かった点

- **Stage 1 の C1（`ADMOB_APP_ID` 空クラッシュ）は再発していない**。
  `project.yml:55` / `pbxproj` ともサンプルアプリ ID が入ったままで、
  ネイティブ 2 面のユニット ID は `""` を追加しただけ（= 枠が出ない）という正しい足し方。
  `xcodegen generate` 済みで `pbxproj` にも 2 キーが反映されている（IOS-8 を踏んでいない）。
  実機相当の確認として、ビルド成果物をシミュレータへ install → launch し
  12 秒後もプロセスが生存することを実測した（IOS-7 の回帰なし）。
- **Stage 1 の C3（no-fill で空カードが残る）を最初から踏襲できている**。
  `nativeAdView` に `onFailure` を持たせ、`didFailToReceiveAdWithError` と
  「ルート VC が取れない」経路の両方で呼んでいる。`NativeAdSlot` は `didFailToLoad` で
  枠ごと高さ 0 に畳む。ロード前に `AdCardChrome` を描かない設計なので、
  「広告」ラベルだけの空カードが出る余地が構造的に無い。
- **IOS-5 を守れている**。`Features/Applications/ApplicationListView.swift` /
  `Features/Home/HomeView.swift` / `Features/Ads/PlacementAdSlot.swift` は
  `SwiftUI` / `DesignSystem` / `Domain` しか import しておらず、`GoogleMobileAds` /
  `DataStore` / `Network` は一切参照していない。SDK 型は `App/Ads/*.swift` の
  `#if canImport(GoogleMobileAds)` に封じられたまま。`AdNativeCardContent` を
  SDK 非依存の値型として切ったのは正しい境界の引き方。
- **`PlacementAdSlot` を `format:` 引数で拡張した判断は妥当**。
  判定・ラッチ・オンライン再測定（F4-1〜F4-6 / M1 の `shouldRemainVisible`）は
  バナーとネイティブで完全に共通なので、`NativePlacementAdSlot` を新設すると
  この 60 行を二重管理することになる。DesignSystem 側だけを差し替える形が既存の粒度に合う。
- **インデックス計算を `Domain` の純粋関数に寄せた**（`AdInlineSlots`）。
  E13（5 件未満）を含む境界が XCTest で固定されている。
  `stride(from:4, to:itemCount, by:10).prefix(2)` は 4 / 5 / 14 / 15 / 24 / 25 件すべてで
  正しく、オフバイワンは無い（テストも境界の両側を押さえている）。
- **配置が仕様どおり**。ホームは `pendingSection` の後（`HomeView.swift:150-156`）で
  `StatRow` 直下ではない（`docs/07:390` / F2-1）。申込一覧はリストのみで、
  ツアー表側（バナー）には手を入れていない（F2-3 / F2-4 の分離が保たれている）。
- **`AdNativeCard` が F5 を満たす**。「広告」ラベルは `AdCardChrome` 経由（F5-1）、
  形状トークンは `ticket-row` と同じ（F5-2）、色は `DS.Gray.*` のみで推しカラー非適用（F5-3）、
  CTA は枠線のみで `btn-primary-block` と区別できる（F5-4）、
  フォントは `DSFont.bodyBold`=16 / `DSFont.caption`=14 で 14px 未満なし（F5-5）、
  `icon == nil` でアイコン領域ごと省く（F5-6 / E4）。AdMob 標準テンプレートは不使用。

---

## 検証結果（修正後）

| コマンド | 結果 |
|---|---|
| `cd meigicho/Packages/Domain && swift test` | 188 tests / 0 failures |
| `cd meigicho/Packages/DesignSystem && swift test` | 1 test / 0 failures |
| `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` | **BUILD SUCCEEDED** |
| シミュレータ install → launch（iPhone 17 Pro / jp.meigicho.app） | 12 秒後もプロセス生存（クラッシュなし） |
| レイアウト最小ハーネス（修正前 / 修正後） | 修正前: 枠 98pt 固定・後続に重なり。修正後: 実寸まで伸び重なりなし |

## 残る手動確認（実 ID 取得後）

1. `ADMOB_UNIT_HOME_NATIVE` / `ADMOB_UNIT_APPLICATIONS_NATIVE` に実 ID（または Google の
   ネイティブテストユニット `ca-app-pub-3940256099942544/3986624511`）を入れ、
   ホーム最下部と申込一覧 5 件目の後にカードが出ること（F2-1 / F2-3）。
2. カードのタップで遷移し、AdMob 管理画面のクリックが **1 回**だけ計上されること（N-M1）。
3. Dynamic Type 最大でカードが後続コンテンツに重ならないこと（N-C1 の修正確認 / E18）。
4. no-fill を意図的に起こし、空カードが残らないこと（F4-4）。
5. 申込一覧で 2 枚目が出ないこと自体は現行仕様どおり（N-M3）。2 枚出す判断をした場合は
   `AdGatekeeper` の改訂とテスト追加が必要。
