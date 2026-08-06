# questions — account-deletion（Inception）

App Store Review Guideline 2.5 対応のアカウント削除機能。
**確定回答はこのファイルに `[Answer]:` として書き戻す**（rule 01）。未回答のものは `[推奨]` を暫定採用して `requirements.md` に落としてあるが、
**Q2 / Q3 / Q6 は実装着手前にユーザー確認が必要**（審査リスク・スコープに直結する）。

作成: 2026-08-05 / 起票: aidlc-planner

---

## Q1. 削除の即時性（物理削除 vs 猶予期間付き論理削除）

現状の一次情報:

- `docs/08-compliance-risk.md:399` — 「**猶予期間を置かない**（即時削除）。ただし削除前に『データを書き出す』導線を必ず提示する」
- `apps/api/prisma/schema.prisma` — `User` に `deletedAt` 列は**無い**。子テーブル（identities/memberships/tours/events/applications/companions）にはある
- 物理削除バッチの基盤（pg_cron / Cloud Scheduler）は**未整備**（`docs/09-roadmap.md:423` は Phase 1 後の導入と記載）

| 案 | 内容 | 追加コスト | 判定 |
|---|---|---|---|
| A（**推奨**） | **即時物理削除**。`DELETE /v1/me` の 1 トランザクションで全関連行を削除 | Service 1 本 + spec | **採用推奨** |
| B | 30 日猶予のソフトデリート | `users.deleted_at` 追加 / 全認証経路のフィルタ / `apple_sub`・`google_sub`・`email_normalized` の unique 制約と削除済み行の衝突回避（同じ Apple ID で作り直せなくなる）/ 復元 UI / 物理削除バッチ基盤の新設 | 却下推奨 |
| C | `users` 行だけ tombstone として残す | 監査以外の用途が無く、保存期間の最小化に逆行 | 却下推奨 |

**[推奨]**: A（即時物理削除）。`docs/08` の既決事項と一致し、B は「同一 Apple ID で再登録できない」という致命的な副作用を持つ。
復元不可であることは iOS の確認 UI で明示する。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q2. Sign in with Apple のトークン失効（**審査リスクあり・要判断**）

Apple は「Sign in with Apple を採用し、かつアカウント削除を提供するアプリ」に対し、削除時に
**Sign in with Apple REST API の `POST /auth/revoke`（トークン失効）を呼ぶこと**を求めている（Guideline 5.1.1(v) 周辺の運用要件）。

現状:

- BE は `identity_token` の**検証のみ**（`apps/api/src/auth/apple-token.verifier.ts`）。失効に必要な `client_secret`（Team ID / Key ID / .p8 秘密鍵で署名する ES256 JWT）の基盤が**無い**
- iOS も `ASAuthorizationAppleIDCredential.authorizationCode` を**送っていない**（`SignInView.swift:186` は identityToken のみ）

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | 契約に任意フィールド `apple_authorization_code` を**今回確定**し、失効実装は独立タスク（T-BE2）。鍵未設定・API 失敗でも**削除は成功させる**（ベストエフォート） | 推奨 |
| B | 今回は失効を実装しない（削除のみ） | 審査で指摘される可能性を受容するなら可 |
| C | 失効成功を削除の前提条件にする | Apple 側障害で削除できなくなる。却下 |

**A を選ぶ場合にユーザー作業が発生する**: Apple Developer で Key（Sign in with Apple）を作成し、`APPLE_TEAM_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY`（.p8 の中身）/ `APPLE_CLIENT_ID`(bundle id) を `.env` に設定。
エージェントは秘密ファイルを触れないため設定は手動。

**[Answer]**: **A を採用（確定）**。契約に`apple_authorization_code`任意フィールドを含める。失効はベストエフォート（鍵未設定・API失敗でも削除は成功）。`APPLE_TEAM_ID`/`APPLE_KEY_ID`/`APPLE_PRIVATE_KEY`/`APPLE_CLIENT_ID`のユーザー設定は別途本番運用前に必要（今回の実装はブロックしない）。

---

## Q3. 削除前のデータエクスポート導線（**スコープ判断・要判断**）

`docs/08-compliance-risk.md:399,416,439` は「削除画面から CSV で書き出せること（Free でも可）」を要求している。
一方 `docs/09-roadmap.md:133` の CSV/PDF エクスポートは **Phase 2（2-6）**。App Store Guideline 2.5 自体はエクスポートを要求しない。

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | Phase 1 では削除画面にエクスポート導線を置かない。`docs/08` を「エクスポート実装（Phase 2 / 2-6）時に削除画面へ導線を追加する」と更新する | 推奨（リリースブロッカーを増やさない） |
| B | 端末側で既存 GET API（identities / memberships / applications / shares）の結果を JSON にまとめ、共有シートに渡す簡易エクスポートを今回追加（BE 変更ゼロ・iOS 1 タスク） | 法務・信頼性重視なら可 |
| C | CSV を今回フル実装 | Phase 2 の前倒し。却下推奨 |

**[Answer]**: **A を採用（確定）**。Phase 1ではエクスポート導線を置かない。`docs/08-compliance-risk.md`を「エクスポート実装（Phase 2/2-6）時に削除画面へ導線を追加する」と更新する。

---

## Q4. 認証方式ごとの本人確認

| ユーザー種別（判定は `users.password_hash`） | 案 |
|---|---|
| password あり（`auth_providers` に `email`） | **リクエストボディに `password` を必須**。不一致は `AUTH_CREDENTIALS_INVALID` 401（`POST /v1/auth/password` と同じ扱い） |
| Apple / Google のみ | **Bearer（access token）のみで実行可**。UI 側で「削除」と入力させる typed confirmation を誤操作防止として要求 |

却下案: Apple/Google ユーザーにも identity token の再取得（再サインイン）を必須にする
→ 実装コストと失敗経路が増える。ただし **Q2 = A を採用すると Apple ユーザーは `authorization_code` 取得のため実質再サインインになる**ので、その場合は「Apple ユーザーのみ再サインインが本人確認を兼ねる」となる。

追加防御: `DELETE /v1/me` に `@ThrottleAuthUser()`（userId 単位・10 回/5 分。`POST /v1/auth/password` と同設定）を適用し、パスワード総当たりを抑止する。

**[推奨]**: 上表のとおり。
**[Answer]**: **上表を採用（確定）**。

---

## Q5. 削除確認画面に「削除される件数」を表示するか

`docs/08:409-412` のコピーは「名義（4件）／申込（12件）／共有リンク（1件）」と件数を出す。
正確な総数を出すには集計エンドポイントの新設か全件取得が必要（`GET /v1/applications` はページング上限 200）。

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | 件数を出さず、**削除対象の種類を列挙**する文言にする。API 新設なし | 推奨 |
| B | `GET /v1/me/deletion-summary` を新設して正確な件数を返す | 今回のスコープを超える。将来必要になったら追加 |
| C | 端末にロード済みのストア件数を表示 | **不正確な件数を見せうるので却下**（未ロード時に 0 件と表示される） |

**[Answer]**: **A を採用（確定）**。`docs/08`のコピーをAに合わせて更新する。

---

## Q6. サブスクリプション解約の案内文言（**要判断**）

Apple は「削除してもサブスクは自動解約されない」旨の明示を求める（`docs/08:401`）。
現状 IAP / RevenueCat は**未実装**で `entitlement.plan` は常に `free`。

| 案 | 内容 |
|---|---|
| A（**推奨**） | `plan == "plus"` または `in_grace_period == true` のときだけ文言と「サブスクリプションを管理」リンク（`https://apps.apple.com/account/subscriptions`）を表示 |
| B | プランに関わらず常時表示 |

**[推奨]**: A。無関係な Free ユーザーに不安を与えない。IAP 実装時に再確認する。
**[Answer]**: **A を採用（確定）**。`plan=="plus"`または`in_grace_period==true`のときだけ文言表示。

---

## Q7. 共有リンクの扱い

削除ユーザーが発行した `share_links` は `onDelete: Cascade`（`schema.prisma:249`）で物理削除される。
以後 `GET /public/shares/:token` / `PATCH /public/shares/:token/items/:item_key` は行を引けず **`SHARE_INVALID` 404**（iOS 既存文言「この共有リンクは無効です」）。

- 共有先への事前通知は**しない**（相手の連絡先を持たない。仕様上も持てない）
- 共有先が編集中でも、トランザクション完了後は即 404
- 逆に、**削除ユーザーが他人から受け取った共有ボードのトークン**（`KeychainSharedBoardTokenStore`）は自アカウントと無関係なので**消さない**

**[推奨]**: 上記のとおり（明記のみ。追加実装なし）。
**[Answer]**: （未回答 — 暫定採用）

---

## Q8. 削除後に残る access token の扱い

access token は署名検証のみ（`apps/api/src/common/guards/jwt-auth.guard.ts` は DB を見ない）ため、削除後も最大 TTL（既定 3600 秒）は Guard を通過する。

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | 受容する。refresh token 行は削除されるので再取得は不可。iOS は 204 受領後に即クリアするため実経路では発生しない。`GET /v1/me` は `NOT_FOUND` 404、一覧は空を返す | 推奨 |
| B | `JwtAuthGuard` で毎回 users 行の存在を確認 | 全リクエストに 1 クエリ増。却下 |

**残リスク（記録）**: A の場合、削除後の残存 access token で `POST /v1/identities` 等が来ると FK 違反（P2003）→ `AllExceptionsFilter` で `INTERNAL` 500 になりうる（BE-6 の同類）。iOS 経路では起きないため今回は受容し、実運用でログに出たら再検討する。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q9. `DELETE` にボディを付けることの是非

パスワード確認が必要なため、リクエストにボディが要る。

| 案 | 内容 | 判定 |
|---|---|---|
| A（**推奨**） | `DELETE /v1/me` + 任意ボディ `{ password?, apple_authorization_code? }`。NestJS は `@Body()` を受け取れ、`URLSession` も送れる | 推奨（REST 的に素直） |
| B | `POST /v1/me/delete` | ボディ落ちの心配はないが、既存契約に動詞パスが 1 つも無く平仄が崩れる |

**フォールバック条件**（記録）: Cloud Run / 中間プロキシで DELETE のボディが欠落することが実測されたら B に切り替える。その場合は契約・iOS 双方を planner が同時に更新する。

**[Answer]**: （未回答 — A を暫定採用）

---

## Q10. docs 反映範囲

削除機能の確定後に更新が必要な docs:

- `docs/04-api.md` §3.1b — `DELETE /v1/me` を追記
- `docs/08-compliance-risk.md` §2.5 — 「Edge Function `delete-account`」という**旧アーキテクチャ記述**（`:398`）を NestJS の `DELETE /v1/me` に修正。Q3 / Q5 / Q6 の決定に合わせて削除画面のコピーを更新
- `docs/05-ios-client.md` — アカウント削除画面の追記
- `docs/plans/STATUS.md` — 本計画の索引追加
- `CLAUDE.md` 「既知の未整備」— Apple トークン失効の鍵設定（Q2 = A のとき）

**[Answer]**: （未回答 — 上記を暫定採用。docs 更新は実装・レビュー完了後の T-D で行う）
