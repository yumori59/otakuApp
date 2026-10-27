# questions — avatar-upload（Inception）

サインイン済みユーザーが自分のアカウントのプロフィールアイコン（アバター画像）を設定・削除できる機能。
**確定回答はこのファイルに `[Answer]:` として書き戻す**（rule 01）。
本計画はクラウドエージェントが対話なしで起票したため、各問の **[推奨] を暫定採用**して `requirements.md` / `plan.md` に落としてある。
**Q0 / Q3 / Q5 は実装着手前（遅くともドラフト PR のレビュー時）にユーザー確認が必要**（既存仕様の撤回・本番運用・CI 権限に直結する）。

作成: 2026-10-27 / 起票: aidlc-planner

---

## Q0. 既存仕様「画像を持たない（R5-5）」との衝突とロードマップ外であること（**要確認**）

現状の一次情報:

- `docs/01-product-overview.md:119` R5-5「アバター画像は使わず、氏名の頭文字＋背景色で表現する」。`:124` に「意図的な設計（画像なしで Storage / モデレーションコストを回避）」
- `docs/06-infrastructure.md:27,155,485` 「画像なし」「画像アップロードなし」を低コストの工夫・やらないことに明記
- `docs/02-architecture.md:7,155` / `docs/08-compliance-risk.md:28` 「Supabase Storage は使わない」
- `docs/05-ios-client.md:1047` 「R5-5 により画像を一切持たない」
- `docs/09-roadmap.md` にアカウントアバターの項目は**無い**（Phase 0〜3 のいずれにも未計上）

R5-5 の対象は**名義（identity）のアバター**（一覧の `row__avatar`）。今回の要求は**ログインユーザー自身のアカウントアイコン**で、対象が異なる。

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | R5-5 は**名義アバターについては維持**し、例外として「アカウント本人のアイコンのみ画像可。**本人にしか表示しない**」を追記する。roadmap に 1 行追加（Phase 1 系の付帯機能） | 推奨 |
| B | 名義アバターも画像化する | 名義は他人（家族・友人）の個人情報であり肖像の扱いが重くなる。共有先にも表示されモデレーション（Guideline 1.2）が発生。却下 |
| C | 実装しない | ユーザーの明示要求に反する |

**本人にしか表示しない**ことが重要な前提。共有相手（受信箱・SharedBoard）に表示した瞬間に UGC となり、App Store Guideline 1.2（通報・ブロック・フィルタ）の対象になる。今回はスコープ外とし、将来表示するなら別計画で 1.2 対応を含めること。

**[推奨]**: A。docs 01 / 02 / 05 / 06 / 08 / 09 の該当箇所を本計画の T-DOC で更新する。

**[Answer]**: （未回答 — ユーザーの明示要求に基づき A を暫定採用）

---

## Q1. HEIC の扱い（サーバー変換か端末変換か）

要求: 「タイプ（jpeg/png/heic→jpeg）とサイズ制限（5MB）を検証」。

事実:

- サーバーで画像処理するなら Node の事実上の標準は `sharp`（libvips）。**sharp の同梱 libvips は HEIC（HEVC）デコーダを含まない**（特許ライセンスの都合。AVIF は可）。HEIC をサーバーで読むには libvips + libheif + libde265 を自前ビルドしたイメージが必要で、Dockerfile（`node:22-alpine`）の複雑化とライセンス確認が発生する
- iOS は ImageIO で HEIC をネイティブにデコードできる。PhotosPicker の写真は多くが HEIC

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | **HEIC→JPEG 変換は iOS 側で行う**（正方形クロップ・512px・JPEG まで端末で完結）。サーバーは **JPEG / PNG のみ受理**し、HEIC は `415 UNSUPPORTED_MEDIA_TYPE`。サーバーは受理した画像を必ず 512×512 JPEG に**再エンコード**する（メタデータ除去・不正ファイル無害化） | 推奨 |
| B | サーバーでも HEIC をデコード | 上記のビルド・ライセンスコスト。公式クライアントは常に JPEG を送るので得るものが無い |
| C | サーバーは再エンコードせず、マジックバイトと寸法だけ検証してそのまま保存 | EXIF（GPS 位置情報）が端末実装次第で残り得る。公開 URL で配るファイルをクライアントに委ねることになる。却下 |

**[推奨]**: A。「heic→jpeg」は**端末で満たす**。サーバーの検証は JPEG / PNG のマジックバイト判定 + 5MB 上限 + デコード可能性 + ピクセル数上限。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q2. ストレージ（GCS vs Supabase Storage）

| 観点 | GCS（**推奨**） | Supabase Storage |
|---|---|---|
| 既存方針との整合 | Cloud Run・Artifact Registry・Secret Manager と同じ GCP プロジェクト。Terraform（`infra/terraform/`）で管理可能 | `docs/02`・`06`・`08` が**不使用と明記**。方針撤回が必要 |
| 認証情報 | **不要**。Cloud Run の実行 SA（`meigicho-api`）の ADC（キーレス）で書き込める | `service_role` キー（全権限キー）を Secret Manager に追加し API に渡す必要がある |
| IaC | `google_storage_bucket` + バケット単位 IAM で完結 | Terraform 管理外（Supabase は手動運用。`infra/terraform/README.md` 対象外節） |
| リージョン | `asia-northeast1`（`docs/08` の越境回避方針と一致） | ap-northeast-1（同等） |
| 委託先 | Google は既に委託先（Cloud Run） | Supabase も既に委託先（DB）だが「Storage」用途の追記が必要 |
| ローカル開発 | `fake-gcs-server`（Docker）で再現可 | Supabase CLI のローカルスタックが必要（現状未使用） |

**[推奨]**: GCS。秘密情報ゼロ（ADC）・Terraform で管理・既存方針を崩さない、の 3 点で最もシンプルかつ安全。詳細は `storage-design.md`。

**[Answer]**: （未回答 — GCS を暫定採用）

---

## Q3. DB のどこに持つか（`users` 列 / `profiles` 列 / 別テーブル）（**要確認**）

要求: 「ユーザーに `avatarUrl` のような nullable カラムを追加」。ただし「本番 DB にスキーマが反映されないインシデントがあった。コードを寛容に」とも。

事実（`apps/api/src`）:

- `auth.service.ts:85,116,133,164,226` — サインイン / 登録の全経路が `include: { profile: true }`
- `me.service.ts:95` — `GET /v1/me` が `include: { profile: true }`
- `share-recipient-access.service.ts:65` — 受信箱が `include: { owner: { include: { profile: true } } }`
- `auth.service.ts:97,145,190` — 新規登録で `tx.profile.create(...)`（戻り値に全列を読む）

Prisma は `include` / `create` / `update` の既定で**モデルの全スカラー列を SELECT / RETURNING する**。
`profiles` や `users` に列を足して本番 DB へ未反映のままコードがデプロイされると、上記すべてが
`P2022 (column does not exist)` で 500 になり、**サインイン・新規登録・GET /me・受信箱が全ユーザーで止まる**。
nullable にしても防げない（列が「無い」ことが問題なので）。

| 案 | 内容 | 未反映時の影響範囲 | 判定 |
|---|---|---|---|
| A | `profiles.avatar_url` 列（nullable） | **全サインイン・登録・GET /me・受信箱が 500** | 却下推奨（過去インシデントの再発形） |
| B | `users.avatar_url` 列（nullable） | 同上（`users` は全認証経路が読む） | 却下 |
| C（**推奨**） | **別テーブル `user_avatars`**（`user_id` PK/FK・`object_key`・時刻）。行が無い = アバター無し（＝ nullable 相当） | **アバター機能だけ**。既存クエリは新テーブルを一切参照しない。読み取りは `P2021 (table does not exist)` を捕捉して `avatar_url: null` に落とす | **推奨** |

C は「nullable カラム」の文言から外れるが、要求の意図（未反映でも壊れない寛容さ）を構造的に満たす唯一の案。
API 上は `profile.avatar_url: string | null` として見えるので、クライアントから見た契約は A と同じ。

**[推奨]**: C。DB には **URL ではなくオブジェクトキー**（`avatars/<random>.jpg`）を保存し、URL は API が `AVATAR_PUBLIC_BASE_URL` から組み立てる（バケット移行・CDN 導入時に DB を書き換えない）。

**[Answer]**: （未回答 — C を暫定採用）

---

## Q4. 画像の配信方式（公開 URL / 署名付き URL / API プロキシ）

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | バケットは**オブジェクト単位の読み取りのみ公開**（`allUsers` に `roles/storage.legacyObjectReader` = `objects.get` のみ。**一覧取得 `objects.list` は不可**）。オブジェクト名は**アップロードごとに 128bit 乱数**（`avatars/<uuid v4>.jpg`、userId を含めない）。URL を知るのは本人（`GET /v1/me`）のみ | 推奨 |
| B | 非公開バケット + V4 署名付き URL を `GET /v1/me` ごとに発行 | 実行 SA に `iam.serviceAccountTokenCreator`（自分自身への signBlob）が必要。`GET /v1/me` に IAM API 往復が増える。URL が毎回変わり iOS のキャッシュが効かない |
| C | `GET /v1/me/avatar` で API が画像をストリーム | iOS の `AsyncImage` は Bearer を付けられず独自ローダーが必要。Cloud Run の帯域・CPU を消費（`docs/06` の低コスト方針に反する） |

A の注意点:

- `roles/storage.objectViewer` を `allUsers` に付けては**いけない**（`objects.list` を含むため全員のアバターを列挙できる）
- `Cache-Control: private, max-age=31536000, immutable` を付ける。`private` により Google のエッジキャッシュに載らず、**削除後は即座に取得不能**になる（`public` だと削除後も最大 max-age の間エッジに残り得る）。キーは毎回変わるので端末側の長期キャッシュは問題にならない
- 組織ポリシーで Public Access Prevention / Domain restricted sharing が強制されている GCP プロジェクトでは `allUsers` を付与できない。その場合は B に切り替える（`storage-design.md` §6）

**[推奨]**: A。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q5. Deploy API ワークフローに `prisma db push` を追加するか（**要確認**）

詳細な影響分析は `db-schema-and-deploy.md` §3。要点:

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | `deploy-api.yml` に **`db-schema` ジョブ**を追加（`test` → `db-schema` → `deploy`）。`prisma migrate diff` で適用予定 SQL をログに出したうえで **`prisma db push --skip-generate`（`--accept-data-loss` なし）**。失敗したら `deploy` に進まない（旧リビジョンが稼働し続ける）。接続文字列は GitHub Actions Secret `PROD_DATABASE_DIRECT_URL`（Supabase **Session pooler** の 5432 番）。**未設定ならジョブを失敗させる（fail-closed）** | 推奨 |
| B | CI には入れず、PR 説明に SQL を明記して人が手動適用する運用を続ける | 過去インシデントの再発を構造的に防げない |
| C | `prisma migrate deploy`（マイグレーション履歴）へ移行 | 本来の到達点だが、`prisma/migrations/` が無く既存本番 DB のベースライン化（`migrate resolve --applied`）が必要。本機能のスコープを超える。**別計画で起票を推奨** |

A の副作用（要承認）:

- CI（`main` への push で動く workflow）が**本番 DB の DDL 権限を持つ接続文字列**を保持する
- `public` スキーマに `schema.prisma` 外のテーブル・列が手作業で作られていると、db push はそれを DROP しようとして「データ損失あり」で**毎回失敗**する（＝以後のデプロイが全部止まる）。初回導入前に `prisma migrate diff` で本番とのドリフトが無いことを確認する
- 適用はコードより**先**になる（expand → deploy の順）。後方互換な追加変更（テーブル追加・nullable 列追加）しか自動で通らない設計にする（破壊的変更は `--accept-data-loss` が無いので失敗する＝人の判断に戻る）

**[推奨]**: A（同一 PR に含める）。Secret の登録はユーザー作業。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q6. クロップ UI（自動中央クロップ / 対話的クロップ）

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | 選択直後に**中央で正方形に自動クロップ**し、円形プレビューを表示して「この写真を使う / キャンセル」で確定 | 推奨（SwiftUI 標準に対話的クロップ UI は無く、PhotosPicker も編集を提供しない） |
| B | ピンチ・ドラッグで位置合わせできる独自クロップ画面 | DesignSystem に新コンポーネント + ジェスチャー実装。後続で追加可能 |

**[推奨]**: A。B は需要が見えてから別計画。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q7. 本人のアカウントが表示される他の場所

`rg` の結果、本人を表す UI は次の 2 箇所:

1. `AccountView.swift:84` の `ProfileCard`（アカウント設定画面の見出しカード）
2. `HomeView.swift:49-50` のツールバー左上 `Image(systemName: "person.circle")`（アカウント設定への入口）

`IdentityDetailView` の `ProfileCard` は**名義**（他人）のカードなので対象外。`SharePreviewView` / `ListRow` の `AvatarView` も名義。

**[推奨]**: 1 と 2 の両方に表示する。2 はアバター未設定なら現状のアイコンのまま。

**[Answer]**: （未回答 — 推奨を暫定採用）

---

## Q8. ローカル開発でのストレージ

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | `docker-compose.yml` に `fake-gcs-server` を追加し、`make up` だけでアップロード〜表示まで再現できるようにする | 推奨 |
| B | ローカルは未設定（`AVATAR_BUCKET` 空）で `503` を返すだけ | iOS の結合確認が実機・本番相当環境でしかできない |

**[推奨]**: A。ただし `fake-gcs-server` 連携で詰まった場合は B にフォールバックしてよい（`AVATAR_BUCKET` 空 = 機能無効の経路は A でも必須）。

**[Answer]**: （未回答 — A を暫定採用）
