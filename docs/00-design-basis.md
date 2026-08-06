# 00. 設計前提サマリ（Design Basis）

このドキュメントは、以降の全設計書が共有する前提・決定事項を1枚に集約したものです。
各章はここで確定した決定を前提に詳細化します。矛盾が生じた場合はこのドキュメントを正とします。

- 対象プロダクト: **参戦名義帳**（仮称 / コードネーム `meigicho`）
- 元モック: `meigi-app-moc-dads.html`（デジタル庁デザインシステム v2.16.0 準拠のiPhoneモック）
- 想定開発体制: **個人〜2名**、副業〜小規模スタートアップ規模
- 最終更新: 2026-07-31

---

## 1. プロダクト一行定義

> 複数のファンクラブ名義（自分・家族・友人）と、その名義で出したライブ申込・当落を1か所で管理し、
> 名義を貸してくれた人や同行者と必要な範囲だけ共有できるiOSアプリ。

### コアジョブ（ユーザーが本当に解決したい4つ）

| # | ジョブ | モック上の該当機能 |
|---|--------|-------------------|
| J1 | FCの**更新期限を絶対に落とさない** | ホームの「更新期限が近い名義」/ `renewalBadge` |
| J2 | **誰の名義でどこに申し込んだか**を忘れない・重複を管理する | 申込一覧、ツアー表（`screenApplicationsTable`） |
| J3 | **当落と座席**を記録し、ツアー単位で俯瞰する | 申込詳細のステータス切替、ツアー表 |
| J4 | **名義主・同行者と共有**する（貸してくれた人への説明責任） | 共有プレビュー、ツアー共有（`window.storage`） |

J1・J2 が「毎日開く理由」、J4 が「他人を連れてくる導線」、J3 が「蓄積による乗り換えコスト」。

---

## 2. スコープの確定

### MVP（Phase 0 / ローカル完結）に含める
- 名義（identity）のCRUD、関係性・**名義カラー**・備考
- FC会員情報（membership）のCRUD、更新日・年会費・会員番号
- 申込（application）のCRUD、代表者・同行者（最大3）・申込日・当落発表日・ステータス（下書き含む）・座席
- ツアー単位のグルーピング表示（リスト / ツアー表）
- 更新期限 / 当落発表日の**ローカル通知**
- ホームのサマリ（名義数、30日以内更新、発表待ち）と**直近の参戦予定（当選分）**
- アプリ表示名・背景カラー（端末ローカルで可）

### Phase 1 に含める
- アカウント（**Sign in with Apple 必須**。Google / メールは任意）
- アカウントID・ユーザーネーム・複数端末同期
- **共有リンク（Web・読み取り専用）**＋共有相手アカウントIDの記録
- サブスクリプション（Plus）と広告
- 統計（名義別当選率など）

### Phase 2 以降
- 共同編集ボード（モックのツアー表編集はここに相当）
- ウィジェット / Live Activity、Android / Web版

### 明示的にやらないこと（Non-goals）
- **チケットの売買・譲渡・価格提示に関わる一切の機能**（ストア審査・法務リスク。詳細は `08`）
- FCサイトへの自動ログイン・スクレイピング・代行申込
- 決済代行・割り勘の実送金
- チャット / SNS 的な公開タイムライン

---

## 3. 技術スタックの決定

| レイヤ | 採用 | 備考 |
|--------|------|------|
| iOS クライアント | **Swift 6 / SwiftUI（iOS 17+）** | ユーザー指定。`@Observable` + SwiftData が使える最低ライン |
| ローカル永続化 | **SwiftData** | Phase 0 では唯一の真実の源（SSoT） |
| BE | **NestJS（TypeScript）+ Prisma** | ユーザー指定。**Controller → UseCase → Service → Prisma**（[02 ADR-009](./02-architecture.md#adr-009-nestjs-は-controller--usecase--service--prisma)） |
| ランタイム | **GCP Cloud Run** | コンテナ・scale-to-zero。低トラフィック時は実質アイドル課金を避けやすい |
| DB | **Supabase PostgreSQL**（ホスティングのみ。Free プラン） | 標準 Postgres。NestJS + Prisma が唯一のクライアント（`DATABASE_URL`）。初期代替候補: Neon Free |
| 共有ボード | **iOS アプリ内 SharedBoard**（`GET/PATCH /public/shares/:token`） | **アプリ不要の独立 Web ビューは作らない**（2026-08-05 決定）。トークン付きリンクをアプリで開く |
| 認証 | **Sign in with Apple（必須）** → NestJS が検証し自前 JWT。Google / メールは任意 | Phase 0 は認証なし。モックは Google+メールだが審査都合で Apple を主軸にする（[10-mock-delta](./10-mock-delta-2026-07-31.md)） |
| プッシュ通知 | 原則 **ローカル通知**、共有更新のみ APNs（Phase 2） | Cloud Scheduler 常駐を避ける |
| 課金 | **StoreKit 2 + RevenueCat** | Webhook を NestJS が受信 |
| 広告 | **Google AdMob** | バナー + ネイティブ + リワード |
| 監視 | Sentry + Cloud Logging / Monitoring | |
| CI/CD | GitHub Actions → Artifact Registry → Cloud Run / Xcode Cloud | |

### BE 選定理由（なぜ NestJS + Cloud Run か）

ユーザー意向（NestJS で自前APIを持ち、GCP Cloud Run で動かす）を第一に採用します。この構成がこのアプリに合う点は次の通りです。

1. **認可・課金・共有トークンをアプリケーション層で明示制御できる。**
   「名義3件制限」「共有リンクのマスキング」「RevenueCat Webhook」は Guard / UseCase / Service に自然に載る（層構成は [02 ADR-009](./02-architecture.md#adr-009-nestjs-は-controller--usecase--service--prisma)）。
2. **Cloud Run の scale-to-zero** により、Phase 1 初期のリクエストが少ない期間でも常駐VMを持たずに済む。
   Supabase Free で Postgres をホスティングすれば DB も ¥0 から始められる。コストの支配項は DB 有料化（Supabase Pro 移行等）まで **Cloud Run 等の従量課金**に下がる（詳細は `06`）。
3. **PostgreSQL + Prisma** で集計ビュー（当選率・更新期限・ツアー表）をそのまま使える。
   DBは標準SQLなのでロックインが浅い。
4. NestJS のモジュール境界（Auth / Identities / Applications / Sync / Shares / Billing）が
   モックのドメイン分割と対応しやすく、1〜2名でも見通しを保てる。

### 採用しなかった候補と理由

| 候補 | 却下理由 |
|------|---------|
| Supabase | BaaS 直結（Auth / PostgREST / RLS）は却下。**Postgres ホスティングのみは採用**（NestJS + Prisma 経由、`DATABASE_URL` 接続） |
| Firebase / Firestore | 集計・複合クエリが弱く、非正規化負債が大きい |
| CloudKit のみ | トークン付き公開共有 API（J4）を自前で持ちにくい |
| Vapor（Swift） | 言語統一は魅力だがエコシステムと採用要件（Nest希望）に合わない |
| GKE / Compute Engine 常駐 | 初期の低コスト方針に反する。Cloud Run で十分 |

> 以前の設計案では Supabase BaaS を推奨していました。本版ではユーザー指定により NestJS + Cloud Run に切り替えます。テーブル設計（`03`）はほぼそのまま流用できます。

---

## 4. アーキテクチャ方針

```
[iOS App]  SwiftUI View → @Observable Store → Repository → ①SwiftData(local)  ②HTTP Client(NestJS)
                                                                 ↑
                                                     SyncEngine（updated_at ベースの差分同期）
[GCP]      Cloud Run (NestJS) ── Prisma ── DATABASE_URL ── Supabase Postgres（ホスティングのみ）
           Secret Manager / Artifact Registry / Cloud Logging
[共有]     iOS SharedBoard → NestJS GET/PATCH /public/shares/:token（Bearer 不要・token のみ）
```

- **ローカルファースト**: 会場・移動中のオフラインでも全履歴が読める。UIはSwiftDataのみを読む。
- **同期は Last-Write-Wins**（`updated_at` 比較 + `deleted_at` によるソフトデリート）。CRDTは過剰。
- **書き込みは楽観的更新**: ローカル即反映 → キューでサーバー送信 → 失敗時はリトライ&競合解決。
- **認可の正は NestJS**（`owner_id` をサービス層で強制）。DBのRLSは任意の二重防衛。
- Cloud Run は **min instances = 0** を既定とし、コールドスタートを許容する（同期はバックグラウンド）。

---

## 5. データモデルの骨格（確定）

モックは `applications` に公演名・会場・ツアー名を文字列でべた書きしていますが、
ツアー表機能・重複申込検知・統計のために **artist / tour / event を正規化** します。

```
profiles ─┬─< identities ─< memberships >─ fan_clubs >─ artists
          │        │                                       │
          │        └──< application_companions              │
          ├─< applications >── events >── tours ────────────┘
          │        │              └────── venues
          ├─< share_links
          ├─< device_tokens
          └── entitlements
```

主要な設計判断:

| 論点 | 決定 |
|------|------|
| 「同じ公演に別名義で複数申込」 | `applications` が `(event_id, rep_identity_id, round_name)` で複数行。UNIQUE制約は張らず、**重複は検知して見せる**（モックid:101/109 がこのケース） |
| 同行者 | `application_companions` に分離。`identity_id` NULL許容（名義未登録の人を氏名テキストで持てる） |
| FC名・アーティスト名 | マスタ（`is_master=true`）＋ユーザー定義の混在。入力揺らぎ用に `*_name_raw` を保持 |
| 会員番号 | **機微情報として暗号化保存**、既定では下4桁のみ表示。共有時はマスキング既定 |
| 削除 | 全テーブル `deleted_at` によるソフトデリート（同期のため必須） |
| 集計 | ビュー `v_identity_stats` / `v_upcoming_renewals` / `v_tour_matrix` として定義 |
| 共有 | Phase 1 は `share_links`（トークン＋read-only）。共同編集（Phase 2）は `boards` / `board_members` を追加 |

---

## 6. 収益化方針（確定した骨子）

ユーザー指定の方針＝**名義数が一定以上でアップグレード / 無料版は広告**を採用します。

| プラン | 価格 | 名義数 | 広告 | 主な機能 |
|--------|------|--------|------|---------|
| Free | ¥0 | **3名義まで** | あり | 申込記録は無制限、ローカル通知、共有リンク1本 |
| Plus | 月 ¥350 / 年 ¥2,800 | 無制限 | なし | 端末間同期、共有リンク無制限、統計、エクスポート、共同編集(Phase 2) |

- **申込件数は絶対に制限しない**。蓄積データこそが乗り換えコストであり、制限すると記録習慣自体が壊れる。
- 制限は「名義数」に集中させる。名義追加はユーザーが価値を認めた**後**の行動なので、ペイウォールが自然な位置に来る。
- 広告は**当落確認の直前後に出さない**（感情的な瞬間の体験破壊を避ける）。リワード広告で「30日間+1名義枠」を提供し課金への踏み台にする。

詳細・試算は `07-monetization.md`。

---

## 7. 最大のリスク（設計の初期段階から織り込む）

| リスク | 影響 | 対応方針 |
|--------|------|---------|
| **ストア審査で「転売・名義貸し支援」と誤認** | リリース不可・アカウント停止 | 訴求を「家族/友人と一緒に応募した記録の管理」に統一。譲渡・価格・取引機能を一切持たない（`08`） |
| **他人の個人情報（氏名・FC会員番号）の預託** | 個人情報保護法上の安全管理措置義務、漏洩時の重大な信用失墜 | 会員番号の暗号化、下4桁表示、共有時マスキング既定、保存しない選択肢の提供（`08`） |
| ユーザー数が伸びずインフラ費が先行 | 撤退コスト | Phase 0 を**インフラ費0円**で出してPMF検証（`06`/`09`） |
| 年1回しか使わない機能（FC更新）で継続率が落ちる | 解約・離脱 | 申込・当落の記録を日常接点に。通知を価値の主軸に据える |

---

## 8. ドキュメント構成

| ファイル | 内容 |
|----------|------|
| `00-design-basis.md` | 本書。全体の前提と決定事項 |
| `10-mock-delta-2026-07-31.md` | モック再レビュー差分と取り込み方針 |
| `01-product-overview.md` | プロダクト要件、画面一覧、ユースケース、用語集 |
| `02-architecture.md` | アーキテクチャ詳細、技術選定ADR、同期設計 |
| `03-database.md` | ER図、DDL、RLSポリシー、インデックス、マイグレーション |
| `04-api.md` | API設計（PostgREST / RPC / Edge Functions）、エラー規約 |
| `05-ios-client.md` | iOSアプリ設計（レイヤ構成、画面実装方針、通知、オフライン） |
| `06-infrastructure.md` | インフラ構成、コスト試算、監視、バックアップ、CI/CD |
| `07-monetization.md` | 収益化設計、プラン仕様、広告配置、売上試算、計測 |
| `08-compliance-risk.md` | ストア審査対策、個人情報保護、規約、セキュリティ |
| `09-roadmap.md` | フェーズ計画、工数見積り、マイルストーン、KPI |
