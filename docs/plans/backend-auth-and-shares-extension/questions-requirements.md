# questions — backend-auth-and-shares-extension

確定回答はこのファイルに `[Answer]:` として残す（rule 01「チャット流しっぱなし禁止」）。
**2026-08-02 時点で Q1〜Q8 は確定済み。Q9 のみ `[Assumed]` のまま進行をユーザーが承認（低リスク）。**

対象: (1) Google Sign-In 追加 (2) Email+Password 追加 (3) 共有リンク Phase 2（共同編集）

---

## A. 認証

### Q1. メール+パスワードのスコープ（リセット・確認メールを含めるか）

`[Assumed]`（当初案）: 登録 / ログイン / パスワード変更の 3 つに絞り、リセットとメール確認はメール送信基盤が未選定のため範囲外にする。

`[Answer]`: **[Assumed] を覆す。パスワードリセットを本計画に含める。** メール送信基盤は **Resend** を採用（API キーの取得・設定はユーザーが行う。planner / 実装エージェントは取得しない）。

確定した内容:

| 項目 | 決定 |
|---|---|
| 追加エンドポイント | `POST /v1/auth/password/reset-request`（メール送信・**レート制限必須**）/ `POST /v1/auth/password/reset`（検証 + 新パスワード設定） |
| リセットの受け渡し方式 | **8 桁の数字コードをメール本文に載せる**（後述の理由で URL リンクを採らない） |
| トークン保存 | 既存 refresh token と同じく **ハッシュのみ保存**（`sha256(userId + ':' + code)`）。平文はメール本文にしか存在しない |
| 有効期限 / 試行 | 15 分 / 誤入力 5 回で当該コード失効。新規発行時に同一ユーザーの未使用コードを失効（有効なのは常に最新 1 本） |
| 依存 | `resend` パッケージの追加を許可。**jest（ts-jest / CJS）で動くことを T0 の完了ゲートで確認**し、ESM 専用等で落ちるなら `fetch('https://api.resend.com/emails')` 直叩きに切り替えてよい（`jose` 撤退時と同じ判断基準） |
| env | `RESEND_API_KEY` / `RESEND_FROM_EMAIL` |
| メール確認（verification） | **引き続き範囲外**。リセットが事実上のメール所有確認として機能する（下記リスク欄） |
| メールアドレス変更 | 範囲外 |

**受け渡し方式を「コード」にした理由と却下案**:

- 却下案 A: **メール内のリンク → Web ページで再設定** — 認証用の Web アプリが存在しない（共有 Web ビューすら未実装 / `docs/09` 1-7）
- 却下案 B: **メール内のリンク → Universal Link で iOS を開く** — 関連ドメインと `apple-app-site-association` の配信が未整備。カスタム URL スキームは容易だが、リンク方式は結局この基盤整備待ちになる
- 採用: **コード方式**は iOS 単独で完結し、将来 Web ができたら同じトークン行にリンク方式を足せる（拡張可能）

**メール未確認のままリセットを使えることのリスクと緩和**:

| リスク | 緩和 |
|---|---|
| 他人のメールアドレスで登録できる（確認していないため） | **リセットが所有確認として働く**。真の所有者はリセットでそのアカウントを取り戻せる。攻撃者が先に登録しても被害者は奪い返せる |
| リセット要求による**アカウント存在確認**（列挙） | `reset-request` は登録の有無に関わらず**常に 202 + 空ボディ**。未登録でも同等の処理時間を通し、応答時間差を作らない |
| コードの総当たり | 8 桁（10^8）+ TTL 15 分 + 試行 5 回で失効 + `reset-request` 3 回 / 15 分 / email + `reset` 10 回 / 15 分 / email |
| メール本文・ログからの漏洩 | コードをアプリログ・エラーメッセージ・レスポンスに出さない。本番で `RESEND_API_KEY` 未設定なら送信時に 500（ログへのフォールバック出力をしない） |

**残課題（本計画のスコープ外だが必ず実施）**: `docs/08-compliance-risk.md` の委託先一覧（`:268` / `:450`）に **Resend** を追記する。法務ドキュメントの更新自体は別作業。

### Q2. 同一メールアドレスの Apple / Google / メール登録をアカウント統合するか

`[Assumed]` 統合しない（別ユーザーとして扱う）。認証の同一性キーは `apple_sub` / `google_sub` / `email_normalized` の 3 本立て。`users.email` は連絡先のまま一意制約を付けない。

`[Answer]`: **確定（Assumed どおり）。統合しない。**

- 帰結: 同じ人が Apple → Google と入ると**アカウントが 2 つできる**（`account_id` も別、データ非共有）。iOS はアカウント画面に現在のログイン方法（`GET /v1/me.auth_providers`）を表示して気づけるようにする
- 却下案（記録）: メール一致での自動統合 — メール確認が無い状態では**アカウント乗っ取り経路**になる / 認証済みでの明示的リンク（`POST /v1/me/auth/link`）— 安全だが本計画では扱わない

---

## B. 共有リンク Phase 2

### Q3. `permission:"write"` の発行にプラン差を設けるか

`[Assumed]`（当初案）: `docs/07-monetization.md:95`（共同編集ボード: Free ×・Plus ○）に従い、**Free は write リンクを発行できない**（`PLAN_LIMIT_SHARE_WRITE` 403）。

`[Answer]`: **[Assumed] を覆す。「発行可否」ではなく「規模」で差をつける。**

| プラン | write 共有 |
|---|---|
| Free | **発行できる。ただし 1 本の write 共有に含められる公演（event）数に上限**（`shareWriteEventLimit`） |
| Plus | 無制限 |

- 実装: `EntitlementsService.shareWriteEventLimit(userId): Promise<number \| null>` を既存 `identityLimit` / `shareLimit` と同じパターンで追加
- `POST /v1/shares` で `permission:"write"` かつ対象 tour の**未削除 event 数 > limit** → `PLAN_LIMIT_SHARE_WRITE` 403（`details: { limit, current }`）
- **上限値の提案: 3 件**（採用理由と却下案は `requirements.md` C8）
- **発行後に event が増えて上限を超えた場合**: 既存リンクは有効のまま。公演の並び（`event_date asc nulls last, event_name asc`）で**先頭 N 公演のみ `editable: true`**、超過分は閲覧のみ（PATCH は `FORBIDDEN` 403）。判定は**閲覧・更新の都度**行うため、プランのダウングレードにも自動追従する
- `read` リンクは公演数の制限を受けない（従来どおり）
- `docs/07` との整合: 本計画の write 共有は `docs/09` の `boards` / `board_members` を伴う本格的な共同編集ボードとは**別物（軽量版）**という位置づけを維持。`docs/07` には「write 共有リンクは Free / Plus とも発行可、Free は公演数に上限」を追記する（追記案は `requirements.md` C8）

### Q4. write 共有で書き換えてよい項目

`[Answer]`: 確定（planner 案どおり）。**`status` と `seat` のみ。** 許可外キーは `forbidNonWhitelisted` で 400。

### Q5. `history_visible = false` の名義の行を write で編集できるか

`[Answer]`: 確定（planner 案どおり）。**行ごと書き込み禁止（`FORBIDDEN` 403）。** 見えないものを書き換えさせない。

### Q6. 既存の read リンクを後から write に昇格できるか

`[Answer]`: 確定（planner 案どおり）。**できない。** `permission` は発行時のみ指定。`PATCH /v1/shares/:id` は新設しない。

---

## C. 横断

### Q7. レート制限を本計画に含めるか

`[Assumed]` `@nestjs/throttler` を導入し、認証系と公開 write のみに適用する。tracker は email / userId / token（**IP は使わない** — Cloud Run 越しの `X-Forwarded-For` 左端は詐称可能）。

`[Answer]`: **確定（Assumed どおり）。導入する。** リセット系 2 本も対象に含める（`api-contract-delta.md` §0）。

**既知の限界（残す）**: `@nestjs/throttler` の既定ストレージはプロセス内メモリ。Cloud Run が N インスタンスに増えると実効上限は N 倍。DB / Redis バックエンドと IP ベースの防御は infra 側の別計画。

却下案（記録）: 自前カウンタ（車輪の再発明）/ 何も入れない（パスワード認証を足す以上不可）/ `locked_until` によるアカウントロック（攻撃者が被害者を恒常的にロックできる DoS）。

### Q8. パスワードハッシュの方式（新規依存を足すか）

`[Answer]`: 確定（planner 案どおり）。**`node:crypto` の `scrypt`**（`N=32768, r=8, p=3, keylen=32, maxmem=64MiB`）。保存形式 `scrypt$N=32768,r=8,p=3$<salt>$<hash>`。比較は `timingSafeEqual`、ログイン時にパラメータが古ければ再ハッシュ。
却下案: `bcrypt` / `argon2`（ネイティブビルド）/ `bcryptjs`（`node:crypto` で足りる）。

### Q9. ロードマップ逸脱の確認（rule 5）

`docs/09-roadmap.md:128` の「共同編集ボード（`boards` / `board_members`・招待・3 段階権限・監査ログ / 10 人日）」は **Phase 2 本体**。本計画はその最小版を Phase 1 に前倒しする。

| | docs/09 2-1（Phase 2 本体） | 本計画 |
|---|---|---|
| メンバー管理 | `boards` / `board_members` + 招待 | 無し（URL を知っていれば編集可） |
| 権限 | 3 段階 | 2 値（`read` / `write`） |
| 監査ログ | 専用テーブル | `share_links.edit_count` / `last_edited_at` + アプリログ |
| 競合解決 | 設計項目 | `rev` による楽観ロック（409） |
| プラン差 | Free × / Plus ○ | 両方発行可・Free は公演数上限（Q3） |

`[Assumed]` 前倒しを許容し、`docs/09` / `docs/10` §3 / `docs/07` に追記する（実装後タスク T3）。
**未回答のまま進行することをユーザーが承認済み（低リスク）。**

`[Answer]`: （未回答 — T3 の docs 追記時に最終確認する）
