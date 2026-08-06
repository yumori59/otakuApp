# questions — admob-integration

`docs/07 §7` / `docs/08 §2.8` / `docs/09 1-10, 1-11` を実装単位へ翻訳する過程で出た未決事項。

- **[要ユーザー判断]** = 回答が無いと計画を確定できない。`[Answer]:` に書き戻す
- **[既定採用]** = planner が妥当なデフォルトを採用済み。異論があれば上書きする

回答は本ファイルの `[Answer]:` 行に追記し、確定後 `requirements.md` / `plan.md` へ反映する。

---

## Q1. 自作 `Network` パッケージ名の衝突 — リネームするか [要ユーザー判断]

**事実（検証済み）**

- `meigicho/Packages/Network`（53 ソースファイル・`import Network` する箇所 21 ファイル）は Apple の `Network.framework` と**モジュール名が同一**。
- この衝突により **RevenueCat SDK は現在無効化されている**（`docs/plans/STATUS.md` §3、`meigicho/project.yml:26-30` でパッケージ依存をコメントアウト、`RevenueCatPurchasesService.swift` を `#if canImport(RevenueCat)` で封鎖）。
- Google Mobile Ads SDK は Objective-C バイナリ XCFramework で、ヘッダが `Network` / `os` などのシステムモジュールを import する。**clang のモジュール解決で自作 `Network` が優先される同種の事故が起きうる**。ただし ObjC バイナリなので RevenueCat（Swift ソース）と挙動が同じとは限らない。**未検証**。

**選択肢**

| # | 案 | 内容 | 影響 |
|---|---|---|---|
| A | Spike 先行（推奨） | まず GoogleMobileAds を SPM 追加してクリーンビルドし、衝突の有無を実測（T0・0.5人日）。衝突したら B に進む | 最小の手戻り。ただし B に進めば +0.5〜1.0人日 |
| B | 先にリネーム | `Network` → `MeigichoAPI`（または `APIKit`）へ機械的リネーム。`project.yml` / `Package.swift` / `import Network` 21 ファイル | AdMob の衝突リスクを消し、**同時に RevenueCat を再有効化できる**（Phase 1 の本番課金に必要）。差分は大きいが機械的 |
| C | リネームしない | AdMob が衝突したら AdMob 側を CocoaPods / 手動 XCFramework に逃がす | ビルド構成が二重化し保守が悪化。非推奨 |

**planner の推奨**: **A → 衝突していれば B**。加えて、衝突が無かった場合でも **B を別計画として起票する**ことを推奨する（RevenueCat 再有効化は AdMob とは独立に Phase 1 のブロッカー）。

`[Answer]:` **A（Spike先行）で採用。2026-08-07 ユーザー承認。**

---

## Q2. ATT（App Tracking Transparency）を実装するか — docs 間の矛盾 [要ユーザー判断]

**矛盾している記述**

| 出典 | 記述 |
|---|---|
| `docs/08-compliance-risk.md:497` | **決定: Phase 1 は非パーソナライズ広告（NPA）固定でリリースし、ATT プロンプトを表示しない。** `NSUserTrackingUsageDescription` を Info.plist に**入れない** |
| `docs/05-ios-client.md:888` | 「ATT は初回起動では求めず、**広告を初めて表示する直前**に…要求します」「**UMP による同意取得も入れます**」 |
| `docs/09-roadmap.md:104`（1-11） | 「**ATT（App Tracking Transparency）ダイアログ**」を作業項目に含む |
| `docs/09-roadmap.md:534`（T7） | 「ATT ダイアログの文面を審査ガイドラインに沿わせる」 |

**planner の推奨**: **`docs/08 §2.8` を正とする（ATT なし・NPA 固定・UMP なし）**。理由:

1. `docs/08` は「決定」として選択肢比較付きで明示され、`07 §7.7` の eCPM 試算も NPA 低下を織り込み済み（相互整合が取れているのは 07↔08 の組）。
2. ATT を出さない方が審査説明とプライバシーラベルが単純（`docs/08:508`）。
3. 制約の弱い方から始めるべき（`docs/08:509`）— NPA→ATT は後から可能、逆は不可。
4. UMP は GDPR/EEA 向け。初期配信国は日本のみのため不要、かつ「SDK を増やさないこと自体を設計判断として優先」（`docs/07:905`）と整合。

**この回答が Yes の場合、計画に docs 修正タスクを含める**: `docs/05-ios-client.md:888` の ATT/UMP 文と `docs/09-roadmap.md:104, 534` の ATT 記述を `docs/08 §2.8` に合わせて修正。

`[Answer]:` **docs/08 §2.8 を正とする（ATTなし・NPA固定・UMPなし）で採用。2026-08-07 ユーザー承認。docs/05:888、docs/09:104,534 は修正済み。**

---

## Q3. リワードのボーナス枠の同時上限は 1 か 2 か — docs 間の矛盾 [要ユーザー判断]

| 出典 | 記述 |
|---|---|
| `docs/07-monetization.md:415` | 「同時に持てるボーナス枠は **1枠まで**（+2 不可）」 |
| `docs/05-ios-client.md:888` | 「**同時上限は2枠**（無限に積ませない）」 |

BE の既存実装（`apps/api/src/entitlements/entitlements.service.ts:87-91`）は `bonusIdentitySlots` を汎用的に加算するだけで、上限は持っていない（テストには `bonusIdentitySlots: 2` のケースもあるが、これは加算ロジックの検証であって仕様上限ではない）。

**planner の推奨**: **1 枠（`docs/07` を正）**。理由: 収益化仕様の SSOT は `docs/07`。かつ「月2回上限」「残り7日以内でのみ再視聴可」という他の制約（`docs/07:415`）と組み合わせると、2枠は「1か月で最大2回視聴 → 2枠同時」を許し、Free で恒常的に名義5件になりうる。ペイウォールの主トリガー（`docs/07 §3`）が弱まる。

**Yes の場合**: `docs/05-ios-client.md:888` の「同時上限は2枠」を「1枠」に修正するタスクを含める。

`[Answer]:` **1枠（docs/07を正）で採用。2026-08-07 ユーザー承認。docs/05:888 は修正済み。**

---

## Q4. 工数と段階リリース — roadmap の 4.0 人日を超える見込み [要ユーザー判断]

`docs/09-roadmap.md:104-105` の見積は 1-10（2.0人日）+ 1-11（4.0人日）= 6.0人日。本計画で洗い出した実作業の planner 見積は **8.0〜10.0人日**（内訳は `plan.md` §6）。超過の主因:

1. **SSV（Server-Side Verification）の BE 実装が丸ごと未計上**。ECDSA 署名検証・Google 公開鍵の取得とキャッシュ・リプレイ防止・claim ライフサイクルで 2.0〜2.5人日。`docs/07:435` は「Edge Function で署名検証」と書いているが、本プロジェクトに Edge Function は存在せず NestJS 実装が必要。
2. **ネイティブ広告のカスタムレイアウト**。`docs/07:447` が「AdMob のネイティブテンプレートは使わず**カスタムレイアウト**で実装」を要求。`GADNativeAdView` の手組み + DADS トークン適合で 1.5〜2.0人日。
3. **`Network` パッケージ名衝突**（Q1）が発生した場合の +0.5〜1.0人日。

**選択肢**

| # | 案 | 内容 |
|---|---|---|
| A | 全部やる（見積を 8〜10人日に改定） | `docs/09` の 1-11 を実測見積に更新 |
| B | 2 段リリース（推奨） | **Stage 1**: バナー（インライン・アダプティブ）のみ 4面 + AdSlot 基盤 + AdMob 初期化 ≈ 4.0人日 → 収益を先に立てる。**Stage 2**: ネイティブ広告 + リワード + SSV ≈ 5.0人日 |
| C | リワードを Phase 2 に送る | 1-10 の「リワードでの一時枠解放」を後送り。ペイウォールの第3導線は当面「準備中」のまま |

**planner の推奨**: **B**。理由: バナーのみでも `docs/07 §8` のブレンド eCPM の 4割（バナー分）が立ち上がり、SSV 未完でも収益が始まる。またリワードは BE+iOS の縦串で最も事故りやすいので、AdSlot 基盤の実地検証後に着手する方が安全。

`[Answer]:` **B（2段階リリース: Stage1バナーのみ→Stage2ネイティブ+リワード+SSV）で採用。2026-08-07 ユーザー承認。docs/09:104-105 は修正済み。**

---

## Q5. AdMob 側の外部リソースの用意 [要ユーザー判断 / ユーザー対応が必要]

エージェントが用意できない。ユーザー対応が必要な項目（`plan.md` §8 にも再掲）:

| # | 項目 | 必要になるタイミング |
|---|---|---|
| U1 | AdMob アカウント作成 + アプリ登録（`GADApplicationIdentifier` = `ca-app-pub-XXXX~YYYY`） | iOS 実配信の直前。開発中は Google のテスト ID で進行可 |
| U2 | 広告ユニット ID **6 本**（`docs/07:877` の命名）: `ios_home_native_bottom` / `ios_identities_banner_bottom` / `ios_applications_native_inline` / `ios_tourtable_banner_between` / `ios_identitydetail_banner_bottom` / `ios_rewarded_identity_slot` | 同上 |
| U3 | AdMob 管理画面で **SSV コールバック URL** を `ios_rewarded_identity_slot` に設定（`https://<cloud-run>/v1/webhooks/admob-ssv`） | リワード実配信前 |
| U4 | 広告カテゴリのブロック設定（ギャンブル / 出会い系 / 投資・仮想通貨 / 美容医療 / **チケット売買・転売**）+ コンテンツレーティング `G` 固定 | 実配信前。`docs/07:449` / `docs/08:545` |
| U5 | 自動再生動画・点滅フォーマットの除外設定 | 実配信前。`docs/07:448` |
| U6 | `SKAdNetworkItems` の Info.plist 追記（Google 提供リスト） | 実配信前。`docs/08:511` |
| U7 | `apps/api/.env.example` への `ADMOB_SSV_ENABLED` / `ADMOB_SSV_KEYS_URL` 追記（既存 BE 残課題と同様、deny 設定でエージェントが書けない） | BE 実装完了時 |

**質問**: U1〜U2（テスト ID でない実 ID）は**いつ用意できるか**。用意前でも実装は進行可（Google 公式テストユニット ID を Debug 構成に埋め、Release は `project.yml` の空文字 → `DisabledAdRenderer` にフォールバック。既存の `REVENUECAT_API_KEY` 未設定時と同じパターン `meigicho/App/Purchases/PurchasesServiceFactory.swift`）。

`[Answer]:`

---

## Q6. SSV の署名検証鍵の管理方法 [既定採用]

**採用**: **秘密鍵の管理は不要**。AdMob SSV は Google 側の ECDSA 秘密鍵で署名され、検証は **Google が公開している公開鍵**で行う。

- 鍵の入手元: `https://www.gstatic.com/admob/reward/verifier-keys.json`（`{"keys":[{"keyId":<number>,"pem":"-----BEGIN PUBLIC KEY-----..."}]}`）
- アルゴリズム: **ECDSA P-256 / SHA-256**、`signature` は web-safe base64、DER エンコード
- BE 実装方針: プロセス内メモリキャッシュ（TTL 24 時間）。リクエストの `key_id` がキャッシュに無ければ 1 回だけ強制リフェッチ（連続リフェッチはレート制限で抑止）
- 環境変数は `ADMOB_SSV_KEYS_URL`（既定値は上記 URL）と `ADMOB_SSV_ENABLED`（未設定/false ならエンドポイントは 503 を返し、付与は一切行わない）のみ。**秘密情報を持たない**

理由: Secret Manager や KMS を増やさずに済み、鍵ローテーションは Google 側で完結する。

`[Answer]:`（異論があれば記入。無ければこの既定で進める）

---

## Q7. リワード付与を「クライアント楽観更新 + Outbox」にしない [既定採用]

**矛盾している記述**

| 出典 | 記述 |
|---|---|
| `docs/05-ios-client.md:887` | 「`GADRewardedAd` の完了で `bonusIdentitySlots += 1`、`bonusExpiresAt = now + 30日` を**ローカル即時反映し Outbox 経由でサーバーへ**」 |
| `docs/07-monetization.md:435` | 「月2回上限をサーバー側 `entitlements` で判定（**クライアント値は信用しない**）。付与は AdMob の SSV を使い、署名検証してから更新」 |
| `docs/08-compliance-risk.md:645, 785` | 「リワード付与は AdMob の SSV で署名を検証してから」「SSV による署名検証、サーバー側の月2回上限」 |

**採用**: **サーバー（SSV）が付与の唯一の正**。クライアントの楽観的更新と Outbox 経由の付与は**実装しない**。`docs/05:887` の記述は誤りとして修正対象に含める。

理由: `docs/07` / `docs/08` が 2 箇所で一致してサーバー判定を要求しており、Outbox 経由の付与は改造クライアントで無制限に枠を増やせる（`docs/08` R15 のリスクそのもの）。UX 上の遅延は claim ポーリング（`plan.md` の `GET /v1/rewards/claims/:id` を 1 秒間隔・最大 15 秒）で吸収する。

`[Answer]:`

---

## Q8. リワード月次カウンタのリセット基準タイムゾーン [既定採用]

**採用**: **JST（Asia/Tokyo）の月初 00:00**。`rewarded_views_reset_at`（date 型）に「当月の 1 日（JST）」を保持し、読み取り時に `reset_at < 当月1日(JST)` なら視聴回数 0 として扱う。

理由: 配信国が日本のみ（`docs/05:890`）。UTC にすると月末深夜に「まだ月が変わっていないのにリセットされる／されない」がユーザーの体感とズレる。`docs/07` にタイムゾーンの記載が無いため planner が決定。

`[Answer]:`

---

## Q9. SSV のローカル/ステージング検証手段 [要ユーザー判断]

SSV コールバックは **AdMob から公開 URL への GET** なので、`localhost:8080` には届かない。検証手段の候補:

| # | 案 | 備考 |
|---|---|---|
| A | ユニットテストのみ（推奨・既定） | Google のサンプル署名 or テスト用鍵ペアで生成した署名を jest で検証。実 AdMob との疎通は本番/ステージング Cloud Run デプロイ後の手動確認 |
| B | ngrok 等でローカルを一時公開 | 実 SSV を受けられるが、`.env` / トンネル設定はユーザー作業 |
| C | ステージング Cloud Run を先に用意 | `infra/` の作業が先行する。Phase 1-16 相当 |

**planner の推奨**: **A**。実 SSV の疎通確認は `plan.md` §7 の手動確認手順（Cloud Run デプロイ後）に回す。

`[Answer]:`

---

## Q10. 広告の「1セッション最大3インプレッション」のセッション定義 [既定採用]

`docs/07:451` の「1セッション最大3インプレッション」の**セッション**が未定義。

**採用**: **アプリがフォアグラウンドに入ってからバックグラウンドに 30 秒以上留まるまで**を 1 セッションとする（30 秒未満の離脱は同一セッション継続）。カウンタは `AdsStore`（Domain・純粋）が保持し、永続化しない。

理由: 「起動から 30 秒間は要求しない」（同 §7.6）と同じ 30 秒を使い、判定ロジックを 1 箇所（`AdGatekeeper`）に閉じられる。

`[Answer]:`
