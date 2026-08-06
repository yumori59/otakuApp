# requirements — account-deletion

App Store Review Guideline 2.5 対応。**アプリ内で完結するアカウント削除**を BE / iOS 双方に実装する。

- 契約の正: `docs/plans/backend-domain-modules/api-contract.md` + `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` + **本ディレクトリの `api-contract-delta.md`**
- 確認事項と回答: `questions-requirements.md`（**Q1〜Q10 未回答。推奨案を暫定採用して本書を確定した状態**。Q2 / Q3 / Q6 は着手前にユーザー確認が必要）
- 上位仕様: `docs/08-compliance-risk.md` §2.5（`:390-419`）

---

## 1. 現状把握（ギャップ分析）

| 層 | 現状 | 出典 |
|---|---|---|
| BE | 削除エンドポイントは**存在しない**。`me` は `GET` / `PATCH` の 2 本のみ | `apps/api/src/me/me.controller.ts:11-22` |
| BE | `User` の関連はすべて `onDelete: Cascade`。ただし **`applications.rep_identity_id` だけ `onDelete: Restrict`** | `apps/api/prisma/schema.prisma:204` |
| BE | `User` に `deleted_at` 列は無い（ソフトデリートは子テーブルのみ） | `schema.prisma:10-34` |
| BE | `PasswordHasher` は `AuthModule` の provider だが **export されていない** | `apps/api/src/auth/auth.module.ts:33-52` |
| BE | Guard は JWT 署名のみ検証し DB を見ない | `apps/api/src/common/guards/jwt-auth.guard.ts:39-52` |
| BE | userId 単位のレート制限デコレータが既にある（10 回/5 分） | `apps/api/src/common/throttling/throttle-route.decorators.ts:35-40` |
| iOS | `AccountView` にログアウトはあるが**削除導線は無い** | `.../Features/Account/AccountView.swift:109-118` |
| iOS | `AuthRepository` に削除メソッドが無い | `.../Domain/Repositories/Repositories.swift:7-27` |
| iOS | ローカル DB（SwiftData / DataStore パッケージ）は**未導入**。永続化は Keychain（refresh token / 共有ボードトークン）と UserDefaults（`auth.signed_in_user` / `theme.seedHex`）のみ | `Packages/` 直下に DataStore 無し |
| iOS | `signOut()` は Keychain とユーザーキャッシュを消すが、`IdentityStore` / `ApplicationStore` / `ShareLinkStore` は消していない（呼び出し側で `profile.clear()` のみ） | `AuthStore.swift:255-268` / `AccountView.swift:112-115` |

### 1.1 計画全体を左右する技術的発見（**重要**）

**`prisma.user.delete()` 一発では削除できない。**
`applications.rep_identity_id` は `onDelete: Restrict`（`schema.prisma:204`。`docs/03-database.md:472-474` が「名義の物理削除を止める安全網」として意図的に設定したもの）。
PostgreSQL の `RESTRICT` は**即時チェック**で、同一文中で参照側（applications）が削除されるのを待たない。
`users` 行を消すと `identities` と `applications` の cascade が発火するが、**どちらが先に処理されるかは保証されない**ため、
`identities` の削除が先に評価されると `applications` がまだ残っており FK 違反（P2003）になる。

→ **Service で明示的な順序（子 → 親）による削除を 1 トランザクションで行う**（§4 D1）。この順序は AC-AD-05 で検証する。

---

## 2. 機能要件（FR）

| ID | 要件 |
|---|---|
| FR-AD-1 | 認証済みユーザーは `DELETE /v1/me` で自分のアカウントと全関連データを**即時・物理**に削除できる |
| FR-AD-2 | `users.password_hash` が非 null のユーザーは、リクエストボディの `password` による本人確認を必須とする |
| FR-AD-3 | Apple / Google のみのユーザーは Bearer のみで実行できる（本人確認は端末側の typed confirmation で担保する） |
| FR-AD-4 | 削除は 1 トランザクションで完結し、途中失敗時は**部分削除を残さない** |
| FR-AD-5 | 削除に伴い、その user の refresh token / password reset code / device token を物理削除する（以後 `POST /v1/auth/refresh` は `AUTH_REFRESH_INVALID` 401） |
| FR-AD-6 | 削除に伴い、その user が発行した共有リンクを物理削除する。以後の `/public/shares/:token` 系は `SHARE_INVALID` 404 |
| FR-AD-7 | iOS はアカウント設定画面（ログアウトと同階層）から削除に到達でき、実行前に「復元できないこと」「削除対象」を明示する |
| FR-AD-8 | iOS は 204 受領後、Keychain の refresh token・メモリ上の access token・ユーザーキャッシュ・各ストアの内容を破棄し、未ログイン状態に戻す |
| FR-AD-9 | 削除に失敗した場合、iOS は**ログアウトせず**エラーを表示し再試行できる |
| FR-AD-10 | 削除済みユーザーへの再度の `DELETE /v1/me` は `NOT_FOUND` 404（冪等ではない） |
| FR-AD-11 | （Q2 = A のとき）Apple ユーザーの `authorization_code` を受け取り、Sign in with Apple のトークン失効を**ベストエフォート**で呼ぶ。失敗しても削除は成功させる |
| FR-AD-12 | （Q6 = A のとき）`plan == "plus"` または `in_grace_period` のとき、サブスクは自動解約されない旨と管理画面へのリンクを削除確認画面に表示する |

## 3. 非機能要件・制約（NFR）

| ID | 要件 |
|---|---|
| NFR-AD-1 | レイヤは Controller → UseCase → Service → Prisma を厳守（ADR-009 / BE-3）。UseCase から Prisma を直接叩かない |
| NFR-AD-2 | 削除は常に `req.user.id` スコープ。ボディやクエリで対象ユーザー ID を受け取らない（BE-4） |
| NFR-AD-3 | `password` / `apple_authorization_code` をログ・エラーメッセージ・例外に出さない |
| NFR-AD-4 | 新しいエラーコードを増やさない（既存の `VALIDATION_ERROR` / `AUTH_CREDENTIALS_INVALID` / `NOT_FOUND` / `RATE_LIMITED` で表現する） |
| NFR-AD-5 | `DELETE /v1/me` に userId 単位のレート制限（10 回 / 5 分）を適用する |
| NFR-AD-6 | 削除の事実は構造化ログに残す（`userId` と `request_id` のみ。メール・名義などの個人データは出さない）。**監査テーブルは作らない**（保存期間最小化） |
| NFR-AD-7 | iOS は BE の契約に無い入力制約を足さない（IOS-4）。パスワード欄に長さ下限を掛けない（旧ポリシーのアカウントを弾かないため。`AuthStore.signInWithEmail` と同じ判断） |
| NFR-AD-8 | Features が Network を直接参照しない（IOS-5）。削除は `AuthRepository` protocol 越し |

## 4. 設計判断（採用と却下）

### D1. 即時物理削除 + 明示的な順序削除（Q1 = A）

**採用**: `DELETE /v1/me` の 1 トランザクションで、以下の順に `deleteMany` → 最後に `user.delete`。

```
application_companions(ownerId)   ← 防御的（applications の cascade でも消えるが、順序を明示する）
applications(ownerId)             ← identities の Restrict を先に外すため必ず identities より前
memberships(ownerId)
identities(ownerId)
events(ownerId)
tours(ownerId)
share_links(ownerId)
device_tokens(userId)
refresh_tokens(userId)
password_reset_codes(userId)
entitlements(userId)
profiles(id = userId)
users(id = userId)                ← 最後
```

- `deleteMany` は `deleted_at` の有無に関わらず**全行**を対象にする（ソフトデリート済みの行も物理削除する）
- `$transaction` には明示 timeout（`{ maxWait: 5_000, timeout: 15_000 }`）を渡す（大量データのアカウント対策）
- **却下 A**: `prisma.user.delete()` に cascade を任せる → §1.1 の `Restrict` により FK 違反になりうる
- **却下 B**: `schema.prisma` の `Restrict` を `Cascade` / `NoAction` に変更する → `docs/03-database.md:472-474` の安全網を弱め、名義の誤物理削除を許してしまう。**スキーマは変更しない**（本計画は DB マイグレーション無し）
- **却下 C**: 猶予期間付きソフトデリート → `questions-requirements.md` Q1 の B 参照（unique 制約と再登録不能の副作用）

### D2. 本人確認（Q4）

- `password_hash != null` → `password` 必須。不一致は `AUTH_CREDENTIALS_INVALID` 401（`ChangePasswordUseCase` と同じ扱い・同じ固定メッセージ）
- `password_hash == null` → ボディ無しで実行可
- **却下**: 全ユーザーに再認証（identity token 再取得）を必須にする → 失敗経路が増え、Google 側の SDK 再実行も必要。誤操作防止は端末側の typed confirmation で足りる

### D3. Apple トークン失効はベストエフォート（Q2 = A）

削除トランザクションの**成功後**に呼ぶ。失敗（鍵未設定 / Apple 側 5xx / タイムアウト）は warn ログのみで 204 を返す。
**却下**: 失効成功を削除の前提にする → Apple 側障害でユーザーが削除できなくなる（Guideline 2.5 に反する）。

### D4. 端末側のクリア範囲（Q7 / FR-AD-8）

| 対象 | 削除時 | 理由 |
|---|---|---|
| Keychain の refresh token（`KeychainTokenStore`） | 消す | セッション終了 |
| メモリの access token / `sessionEpoch`（`ApiClient.clearSession()`） | 消す | 同上 |
| `auth.signed_in_user`（UserDefaults） | 消す | 削除済みアカウントの表示情報 |
| `ProfileStore` / `IdentityStore` / `ApplicationStore` / `ShareLinkStore` | 消す | 画面に残さない |
| `theme.seedHex`（UserDefaults）と `AppSettingsStore.appDisplayName` | 既定値に戻す | アカウント由来の設定（`docs/08:400`「端末内データも破棄」） |
| `KeychainSharedBoardTokenStore`（**他人から受け取った**共有ボードのトークン） | **消さない** | 自アカウントと無関係な受信側の資産 |

**副次的な既存不備の是正**: 現状 `signOut()` 経路も `IdentityStore` / `ApplicationStore` / `ShareLinkStore` を消していない。
削除用に作るクリア処理をログアウトからも呼ぶ（スコープ内と明示する）。

### D5. `DELETE /v1/me` + 任意ボディ（Q9 = A）

`POST /v1/me/delete` を却下（既存契約に動詞パスが無く平仄が崩れる）。フォールバック条件は `questions-requirements.md` Q9 に記録。

### D6. `PasswordHasher` の共有方法

**採用**: `AuthModule` に `exports: [PasswordHasher]` を追加し、`MeModule` が `imports: [AuthModule]` する。
**却下**: `MeModule` が独自に `{ provide: PasswordHasher, useClass: ScryptPasswordHasher }` を持つ → インスタンスが二重になり、将来パラメータを変えたときにズレる。
**却下**: 削除 UseCase を `AuthModule` 側に置く → エンドポイントは `/v1/me` であり、`me` に置くのが自然。

---

## 5. エッジケース

| ID | ケース | 期待 |
|---|---|---|
| E-1 | 2 端末から同時に `DELETE /v1/me` | 片方 204、もう片方は `NOT_FOUND` 404（P2025 を 404 に写す — BE-6） |
| E-2 | 削除中に共有先が `PATCH /public/shares/...` | 行ロックで待機し、完了後は `SHARE_INVALID` 404 |
| E-3 | password ユーザーが誤パスワードを連投 | 10 回/5 分で `RATE_LIMITED` 429 |
| E-4 | 通信断・タイムアウト | 削除は未確定。iOS は**ログアウトせず**エラー表示（FR-AD-9） |
| E-5 | 204 受領後に Keychain 削除が失敗 | 次回起動の refresh が 401 → 既存のサイレントログアウト経路で回収 |
| E-6 | 数千行を持つアカウント | `$transaction` の timeout を 15 秒に設定。超過時は 500 を返し**部分削除は残らない** |
| E-7 | Apple revoke API が失敗 | 削除は成功（204）。warn ログのみ |
| E-8 | 削除後に残存 access token で書き込み | FK 違反 → 500 になりうる。iOS 経路では発生しない前提で受容（Q8） |
| E-9 | 削除直後に同じ Apple ID で再サインイン | **新規ユーザー**として作成（`is_new: true`）。旧データは戻らない |
| E-10 | ゲスト（未ログイン） | 削除導線を表示しない（`AccountView` はゲストに `SignInView` を出すため自然に満たす） |
| E-11 | `password` を送ったが `password_hash` が null のユーザー | `password` は無視して削除を実行（400 にしない。誤って締め出さない） |
| E-12 | ソフトデリート済み（`deleted_at != null`）の子行 | 物理削除の対象に含める |

---

## 6. 受入基準（AC）

### 6.1 BE（jest / `*.spec.ts`）

| AC-ID | 受入基準 |
|---|---|
| AC-AD-01 | `password_hash == null` のユーザーはボディ無しで削除でき、204 を返す |
| AC-AD-02 | `password_hash != null` のユーザーが `password` を送らない → `VALIDATION_ERROR` 400。**削除は実行されない** |
| AC-AD-03 | `password` 不一致 → `AUTH_CREDENTIALS_INVALID` 401。**削除は実行されない** |
| AC-AD-04 | `password` 一致 → 204 |
| AC-AD-05 | 削除は 1 つの `$transaction` 内で行われ、`applications` の削除が `identities` より**前**（Restrict 回避。§1.1） |
| AC-AD-06 | 13 種の削除がすべて `ownerId` / `userId` / `id` = 認証ユーザーで絞られている（他ユーザーの行を消す経路が無い） |
| AC-AD-07 | 対象ユーザーが存在しない（P2025）→ `NOT_FOUND` 404 |
| AC-AD-08 | `DELETE /v1/me` に `@Public()` が付いていない（Guard 適用 — BE-4） |
| AC-AD-09 | `DELETE /v1/me` に userId 単位のレート制限デコレータが付いている |
| AC-AD-10 | トランザクションが例外で失敗した場合、`user.delete` を含むどの削除もコミットされない（Prisma のロールバックに委ねる。spec ではトランザクションコールバックが単一であることを検証） |
| AC-AD-11 | （Q2 = A）`apple_authorization_code` を受け取り、鍵未設定なら失効をスキップして 204 を返す |
| AC-AD-12 | （Q2 = A）失効 API が例外を投げても 204 を返す（削除は成功扱い） |
| AC-AD-13 | エラーメッセージ・ログに `password` / `apple_authorization_code` の値が含まれない |

### 6.2 iOS（`swift test`: Domain / Network。UI は手動確認）

| AC-ID | 受入基準 | 検証手段 |
|---|---|---|
| AC-AD-01-M | `AuthStore.deleteAccount(password:)` 成功時に `clearSession()` が呼ばれ、`state == .signedOut` / `user == nil` になる | `DomainTests`（モック repository + モック session controller） |
| AC-AD-02-M | 失敗時（`AppError` を throw）は `clearSession()` を**呼ばず** `state` を変えない | `DomainTests` |
| AC-AD-03-M | 実行中は `isBusy == true` で二重送信できない | `DomainTests` |
| AC-AD-04-M | `RemoteAuthRepository.deleteAccount` が `DELETE /v1/me` を組み立て、`password` は `password_hash` 相当の入力がある場合のみボディに含める（nil のときキー自体を送らない） | `NetworkTests`（`Endpoint` / エンコード結果の検証） |
| AC-AD-05-M | 401 `AUTH_CREDENTIALS_INVALID` は `.credentialsInvalid` にマップされる（既存マッピングの流用確認） | `NetworkTests` |
| AC-AD-06-M | アカウント設定画面にログアウトと同階層で「アカウントを削除」導線がある | 手動 |
| AC-AD-07-M | 確認画面に「復元できない」「削除対象の列挙」「共有リンクが開けなくなる」の 3 点が表示される | 手動 |
| AC-AD-08-M | password ユーザーはパスワード入力が空だと実行ボタンが無効。Apple/Google ユーザーは「削除」と入力するまで無効 | 手動 |
| AC-AD-09-M | 削除成功後、ゲスト（未ログイン）状態のトップに戻り、前アカウントの名義・申込・共有リンクが画面に残っていない | 手動 |
| AC-AD-10-M | 削除失敗（機内モード）時にログアウトされず、同じ画面で再試行できる | 手動 |
| AC-AD-11-M | ゲスト状態では削除導線が表示されない | 手動 |
| AC-AD-12-M | 削除後にアプリを再起動しても未ログインのまま（Keychain に refresh token が残っていない） | 手動 |

---

## 7. スコープ外

- データエクスポート（Q3 = A のため。Phase 2 / roadmap 2-6）
- 削除サマリ API（Q5 = B を採らないため）
- 猶予期間・復元機能（Q1 で却下）
- `schema.prisma` の変更・マイグレーション（D1 の却下 B）
- 削除の監査テーブル（NFR-AD-6）
- IAP / RevenueCat 連携（未実装のまま。Q6 = A で文言のみ条件表示）
- `JwtAuthGuard` へのユーザー存在確認の追加（Q8 = B で却下）
