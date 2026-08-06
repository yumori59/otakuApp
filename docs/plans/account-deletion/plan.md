# plan — account-deletion

契約の正: **`docs/plans/backend-domain-modules/api-contract.md` + `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` + 本ディレクトリの `api-contract-delta.md`**。
要件・設計判断: `requirements.md`。確認事項: `questions-requirements.md`。

**確定状況（2026-08-05）**: Q1〜Q10 は**未回答**。推奨案を暫定採用して計画を確定した。

| 着手可否 | 対象 |
|---|---|
| ✅ 着手可（推奨案で確定） | **T-BE1** / **T-IOS1** / **T-IOS2**（Q2・Q6 に依存する部分を除く） |
| ⛔ 着手前に回答必須 | **T-BE2**（Q2: Apple トークン失効を実装するか + 鍵 4 変数の準備）/ **T-IOS2b**（Q2 = A のときのみ）/ 削除画面のサブスク文言（Q6） |
| 判断待ち（今回は実装しない前提） | Q3（エクスポート導線）= A を暫定採用。B に変わったら T-IOS3 を起票 |

---

## 1. タスク一覧と依存関係

| Task | 内容 | 依存 | 担当エージェント候補 |
|---|---|---|---|
| **T-BE1** | `DELETE /v1/me`（DTO / UseCase / Service / Controller / module 配線 / レート制限） + spec | なし | `nest-developer`（**model: opus** — 認証・破壊的操作・rule 02 のエスカレーション条件） |
| **T-BE2** | Apple トークン失効（`AppleTokenRevoker` + env 4 変数 + ベストエフォート結線） + spec | T-BE1・**Q2 = A の確定** | `nest-developer`（model: opus） |
| **T-IOS1** | Domain / Network: `AuthRepository.deleteAccount` / `AuthStore.deleteAccount` / DTO / `RemoteAuthRepository` / InMemory 実装 + `swift test` | なし（契約確定済み） | `swift-developer`（model: sonnet） |
| **T-IOS2** | Features: `AccountView` の削除導線 + `AccountDeleteView`（確認 UI・文言・クリア処理） | T-IOS1 | `swift-developer`（model: sonnet） |
| **T-IOS2b** | Apple ユーザーの再サインインで `authorizationCode` を取得して送る | T-IOS2・**Q2 = A の確定** | `swift-developer`（model: sonnet） |
| **R** | レビュー（**別セッション**） | T-BE1・T-IOS2（+ 実施した場合 T-BE2 / T-IOS2b） | `code-reviewer`（model: opus） |
| **T-D** | docs 反映（`04` / `05` / `08` / `STATUS.md` / `CLAUDE.md`） | R 完了後 | オーケストレーター or `nest-developer`（sonnet） |

```
T-BE1 ──────────────► T-BE2(Q2) ──┐
                                  ├── 結合確認 ── R ── T-D
T-IOS1 ── T-IOS2 ── T-IOS2b(Q2) ──┘
```

## 2. 並列実行可能なタスク

| Wave | 並列で発行するもの | 根拠 |
|---|---|---|
| **Wave 1** | **T-BE1 と T-IOS1 を同一メッセージで並列発行** | API 契約が本計画で確定済み（rule 03 の「BE と iOS の独立作業」条件を満たす）。触るファイルが完全に分離 |
| **Wave 2** | **T-BE2（Q2 = A のとき）と T-IOS2 を並列発行** | BE と iOS で別リポジトリ領域。T-IOS2 は T-IOS1 が確定した `AuthStore.deleteAccount` の API にのみ依存し、BE 実装を待たない |
| **Wave 3** | 結合確認（オーケストレーター単独） | `make up` した実 API に対して iOS から削除を実行 |
| **Wave 4** | R（レビュー・集約。並列にしない） | rule 04 |
| **Wave 5** | T-D（docs） | |

### 2.1 同時に触らせないファイル（rule 03）

| ファイル | 所有タスク |
|---|---|
| `apps/api/src/me/**` | **T-BE1**（T-BE2 は `use-cases/delete-me.use-case.ts` のみ、T-BE1 完了後に直列で追記） |
| `apps/api/src/auth/auth.module.ts` | **T-BE1**（`exports: [PasswordHasher]` 追加）→ 完了後に T-BE2 が provider を追加 |
| `apps/api/src/auth/**`（上記以外） | T-BE2 のみ（新規 `apple-token.revoker.ts`） |
| `apps/api/prisma/schema.prisma` | **誰も変更しない**（本計画に DB 変更は無い） |
| `apps/api/src/app.module.ts` / `common/errors/error-codes.ts` / `common/throttling/**` | **誰も変更しない**（既存の `ThrottleAuthUser` とエラーコードを再利用する） |
| `meigicho/Packages/Domain/**` / `meigicho/Packages/Network/**` | **T-IOS1** |
| `meigicho/Packages/Features/**` | **T-IOS2 / T-IOS2b** |
| `meigicho/App/**` | **誰も変更しない**（ストアは `@Environment` 経由で参照する。Composition Root の変更は不要） |

---

## 3. T-BE1: `DELETE /v1/me`（詳細）

### 3.1 新規・変更ファイル

| ファイル | 内容 |
|---|---|
| `apps/api/src/me/dto/delete-me.dto.ts` | `password?: string` / `apple_authorization_code?: string`。両方 `@IsOptional() @IsString() @IsNotEmpty()`。**長さ下限を掛けない**（契約 §1） |
| `apps/api/src/me/dto/delete-me.dto.spec.ts` | 空ボディ許容 / 空文字は 400 / 未知キーの扱い（既存 ValidationPipe 設定に合わせる） |
| `apps/api/src/me/use-cases/delete-me.use-case.ts`（新規ディレクトリ） | `password_hash` の有無で必須判定 → 照合 → `MeService.deleteAccount(userId)` |
| `apps/api/src/me/use-cases/delete-me.use-case.spec.ts` | AC-AD-01〜04・07・13 |
| `apps/api/src/me/me.service.ts` | `deleteAccount(userId)` を追加（順序付き `$transaction`）。**Prisma に触れるのはここだけ**（BE-3） |
| `apps/api/src/me/me.service.spec.ts` | AC-AD-05・06・10 |
| `apps/api/src/me/me.controller.ts` | `@Delete() @HttpCode(204) @ThrottleAuthUser()` |
| `apps/api/src/me/me.controller.spec.ts`（新規） | AC-AD-08・09（`Reflector` でメタデータ検証） |
| `apps/api/src/me/me.module.ts` | `imports: [AuthModule]` / `providers: [..., DeleteMeUseCase]` |
| `apps/api/src/auth/auth.module.ts` | `exports: [PasswordHasher]` を追加（**これ以外変更しない**） |

### 3.2 削除順序（**この順序を変えない**。`requirements.md` §1.1 / D1）

```ts
await this.prisma.$transaction(async (tx) => {
  await tx.applicationCompanion.deleteMany({ where: { ownerId: userId } });
  await tx.application.deleteMany({ where: { ownerId: userId } });   // identities より前（Restrict 回避）
  await tx.membership.deleteMany({ where: { ownerId: userId } });
  await tx.identity.deleteMany({ where: { ownerId: userId } });
  await tx.event.deleteMany({ where: { ownerId: userId } });
  await tx.tour.deleteMany({ where: { ownerId: userId } });
  await tx.shareLink.deleteMany({ where: { ownerId: userId } });
  await tx.deviceToken.deleteMany({ where: { userId } });
  await tx.refreshToken.deleteMany({ where: { userId } });
  await tx.passwordResetCode.deleteMany({ where: { userId } });
  await tx.entitlement.deleteMany({ where: { userId } });
  await tx.profile.deleteMany({ where: { id: userId } });
  await tx.user.delete({ where: { id: userId } });                    // P2025 → NOT_FOUND 404（BE-6）
}, { maxWait: 5_000, timeout: 15_000 });
```

- `where` に `deletedAt` の条件を**付けない**（ソフトデリート済みも物理削除する）
- P2025 の写し替えは Service で捕捉して `AppError.notFound('user not found')`（BE-6）
- 削除成功後に構造化ログ 1 行（`userId` と固定イベント名のみ。メール等は出さない — NFR-AD-3/6）

### 3.3 UseCase の分岐

```
row = auth 経由ではなく MeService/PrismaService で取得した users 行（password_hash と apple_sub を見る）
if (row == null)                          -> NOT_FOUND 404
if (row.passwordHash != null) {
    if (!dto.password)                    -> VALIDATION_ERROR 400 ("password is required for this account")
    if (!await hasher.verify(...))        -> AUTH_CREDENTIALS_INVALID 401（メッセージは CREDENTIALS_INVALID_MESSAGE を再利用）
}
await meService.deleteAccount(userId)
// Q2 = A のときはここで（T-BE2 が）失効をベストエフォート実行
return; // 204
```

- ユーザー行の取得は `MeService` に薄い読み取りメソッドを足す（UseCase から Prisma を直接叩かない — BE-3）
- `AuthService.findUserById` を使うと `MeModule` が `AuthService` に依存するため**使わない**。必要なのは `PasswordHasher` だけ

---

## 4. T-BE2: Apple トークン失効（Q2 = A のときのみ）

| ファイル | 内容 |
|---|---|
| `apps/api/src/auth/apple-token.revoker.ts`（新規） | 抽象クラス + 実装。client_secret JWT（ES256 / `iss=TEAM_ID` / `sub=CLIENT_ID` / `aud=https://appleid.apple.com` / TTL ≤ 6 か月）を `node:crypto` で署名し、**2 段階**で呼ぶ（下記） |
| `apps/api/src/auth/apple-token.revoker.spec.ts` | 2 段階のリクエスト形（`code`+`grant_type` / `token`+`token_type_hint=refresh_token`）/ 鍵未設定でスキップ / fetch 例外を握る / 秘密値（コード・refresh_token・access_token・秘密鍵・client_secret）をログに出さない |
| `apps/api/src/auth/auth.module.ts` | provider + `exports` に追加 |
| `apps/api/src/me/use-cases/delete-me.use-case.ts` | 削除成功**後**に `try { revoke } catch { warn }`。**戻り値・ステータスに影響させない** |
| `docker-compose.yml` | `APPLE_CLIENT_ID` / `APPLE_TEAM_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` |
| `apps/api/.env.example` | **ユーザーが手動追記**（エージェントは deny 設定で書けない） |

**失効は 2 段階**（`/auth/revoke` が受け付ける `token` は `refresh_token` / `access_token` **のみ**で、
クライアントから受け取る `authorization_code` は直接渡せない — 初版の記述が誤っていた。review.md 重大-1）:

1. `POST https://appleid.apple.com/auth/token` に `client_id` / `client_secret` / `code=<authorization_code>` / `grant_type=authorization_code` を form-urlencoded で送り、応答 JSON の `refresh_token` を得る
2. `POST https://appleid.apple.com/auth/revoke` に `client_id` / `client_secret` / `token=<refresh_token>` / `token_type_hint=refresh_token` を form-urlencoded で送る

1 が失敗（非 2xx / `refresh_token` 欠落 / JSON パース失敗）した場合は warn だけ残して 2 を呼ばない。
どちらの段の失敗も**呼び出し元へは伝播させない**（ベストエフォート — D3 / FR-AD-11 / E-7）。
応答本文（`refresh_token` / `access_token` / `id_token`）はログに出さない（NFR-AD-3）。

依存追加は**しない**（`node:crypto` の ES256 署名で足りる。`jsonwebtoken` を入れない）。

---

## 5. T-IOS1 / T-IOS2（詳細）

### 5.1 T-IOS1（Domain + Network）

| ファイル | 内容 |
|---|---|
| `Packages/Domain/Sources/Domain/Repositories/Repositories.swift` | `AuthRepository` に `deleteAccount(password:appleAuthorizationCode:)` を追加（契約 §3.1） |
| `Packages/Domain/Sources/Domain/AuthStore.swift` | `deleteAccount(password:appleAuthorizationCode:) async throws` を追加。成功時は `signOut()` と同じ後始末（`session.clearSession()` / `userCache.clear()` / `user = nil` / `state = .signedOut`）を行うが、**`POST /v1/auth/logout` は呼ばない**（refresh 行はサーバー側で削除済み）。失敗時は状態を変えずに throw |
| `Packages/Domain/Sources/Domain/Preview/InMemoryRepositories.swift` | `InMemoryAuthRepository` に実装（成功を返すだけ） |
| `Packages/Network/Sources/Network/DTO/AuthEmailDTO.swift` | `DeleteAccountRequest`（契約 §3.2） |
| `Packages/Network/Sources/Network/Remote/RemoteAuthRepository.swift` | `sendVoid(.versioned(.delete, "/me", body:))` |
| `Packages/Domain/Tests/DomainTests/AuthStoreTests.swift` | AC-AD-01-M〜03-M |
| `Packages/Network/Tests/NetworkTests/...` | AC-AD-04-M・05-M |

**`NOT_FOUND` の特例**（契約 §3.3）: `AuthStore.deleteAccount` は `.notFound` を受けた場合も**成功と同じ後始末を行ってから** throw する。呼び出し側は文言だけ出し分ける。

### 5.2 T-IOS2（Features）

| ファイル | 内容 |
|---|---|
| `Packages/Features/Sources/Features/Account/AccountView.swift` | ログアウトボタンの**直下**に「アカウントを削除」（destructive）。`.sheet` で `AccountDeleteView` を出す。ゲスト時は表示されない（既存の `auth.isGuest` 分岐で自動的に満たされる） |
| `Packages/Features/Sources/Features/Account/AccountDeleteView.swift`（新規） | 確認 UI・実行・完了処理 |

**`AccountDeleteView` の要件**

1. 見出し「アカウントを削除します」+ 「削除すると次のデータがすべて削除され、**復元はできません**」+ 削除対象の列挙（名義とファンクラブ会員情報 / 申込の記録 / 発行済みの共有リンク（**削除後は相手が開けなくなります**））。**件数は出さない**（Q5 = A）
2. サブスク文言は `profile.plan == .plus` または `inGracePeriod` のときのみ表示 + 「サブスクリプションを管理」（`https://apps.apple.com/account/subscriptions`）（Q6 = A）
3. 確認入力
   - `profile.hasPasswordLogin == true` → **パスワード入力欄**（`.textContentType(.password)` / `SecureField`）。空でなければ実行可能
   - それ以外 → **「削除」と入力**するテキストフィールド。完全一致で実行可能
4. 実行ボタンは destructive。`auth.isBusy` 中は無効 + `ProgressView`「削除しています…」
5. 成功時: `auth.deleteAccount` の後始末に加えて **画面側で** `profile.clear()` / `identityStore.clear()` / `applicationStore.clear()` / `shareLinkStore.clear()` / `appSettings` を既定に戻す / `theme.apply(hex: "#0017C1")` を実行し、シートを閉じる（`requirements.md` D4）。`KeychainSharedBoardTokenStore` は**触らない**
6. 失敗時: `ErrorBar` にエラー文言（契約 §3.3 の表）。**ログアウトしない**。再試行可能
7. 上記 5 のクリア処理は `AccountView` のログアウト経路からも呼ぶ（既存の取りこぼし是正。`requirements.md` D4）

### 5.3 T-IOS2b（Q2 = A のときのみ）

`profile.authProviders` に `"apple"` が含まれるとき、実行ボタンで `SignInWithAppleButton` 相当の再認可を走らせ、
`ASAuthorizationAppleIDCredential.authorizationCode` を UTF-8 文字列にして `appleAuthorizationCode` に渡す。
**キャンセル時はエラーにせず削除を中止**（`AuthStore.failAppleSignIn` と同じ扱い）。
再認可に失敗した場合は `appleAuthorizationCode: nil` で削除を続行してよい（失効はベストエフォート）。

---

## 6. 受入基準 → テストケース対応

### 6.1 BE（Red 先行。`cd apps/api && npm test`）

| AC-ID | テストファイル | テスト名（例） |
|---|---|---|
| AC-AD-01 | `me/use-cases/delete-me.use-case.spec.ts` | `password_hash が null なら password 無しで削除する` |
| AC-AD-02 | 同上 | `password_hash があり password 未指定なら VALIDATION_ERROR で削除しない` |
| AC-AD-03 | 同上 | `password 不一致なら AUTH_CREDENTIALS_INVALID で削除しない` |
| AC-AD-04 | 同上 | `password 一致なら削除する` |
| AC-AD-05 | `me/me.service.spec.ts` | `applications を identities より先に削除する（Restrict 回避）` — モック tx の呼び出し順序を配列で記録して検証 |
| AC-AD-06 | 同上 | `全ての deleteMany が認証ユーザーのスコープで呼ばれる` — 各 `where` に userId が入っていること |
| AC-AD-07 | 同上 | `P2025 を NOT_FOUND に写す` |
| AC-AD-08 | `me/me.controller.spec.ts` | `DELETE ハンドラに @Public() が付いていない` |
| AC-AD-09 | 同上 | `DELETE ハンドラに userId 単位のスロットルが付いている` |
| AC-AD-10 | `me/me.service.spec.ts` | `削除は単一の $transaction 内で行われる` |
| AC-AD-11・12 | `auth/apple-token.revoker.spec.ts` + `delete-me.use-case.spec.ts` | `鍵未設定ならスキップして成功する` / `失効が throw しても削除は成功する` |
| AC-AD-13 | `delete-me.use-case.spec.ts` | `例外メッセージに password の値が含まれない` |

Prisma は既存 spec と同じくモック（`me.service.spec.ts:49-56` の形）。**実 DB 統合テストは現状未整備**（`CLAUDE.md` 既知の未整備）なので、削除順序は「モック tx の呼び出し順序」で担保し、**実 DB での 1 回の手動確認を §7 に必須項目として入れる**。

### 6.2 iOS

| AC-ID | 手段 |
|---|---|
| AC-AD-01-M〜03-M | `cd meigicho/Packages/Domain && swift test`（モック repository / モック `AuthSessionController`） |
| AC-AD-04-M・05-M | `cd meigicho/Packages/Network && swift test` |
| AC-AD-06-M〜12-M | 手動確認（§7） |

---

## 7. 検証ゲート・手動確認手順

### 7.1 機械ゲート（`CLAUDE.md`）

```bash
cd apps/api && npx tsc --noEmit && npm test && npm run build
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build \
  CODE_SIGNING_ALLOWED=NO build
cd meigicho/Packages/Domain && swift test
cd meigicho/Packages/Network && swift test
```

### 7.2 実 DB での手動確認（**T-BE1 の完了条件。Restrict の実挙動を確認する唯一の手段**）

```bash
make up
# 1. register でユーザーを作る
# 2. identity → membership → application（tour/event 込み）→ share link を 1 件ずつ作る
# 3. DELETE /v1/me（password 付き）→ 204 を確認
# 4. 同じ DELETE をもう一度 → 404 NOT_FOUND
# 5. 旧 refresh_token で POST /v1/auth/refresh → 401 AUTH_REFRESH_INVALID
# 6. 削除した共有リンクの GET /public/shares/:token → 404 SHARE_INVALID
# 7. 同じ email で register → 201（is_new: true）
```

**3 で 500（P2003 の FK 違反）が出たら削除順序の誤り。** `requirements.md` §1.1 に戻ること。

### 7.3 iOS 手動確認（AC-AD-06-M〜12-M）

1. メール+パスワードでログイン → アカウント設定 → 「アカウントを削除」がログアウトの直下にある
2. 確認画面に「復元できない」「削除対象の列挙」「共有リンクが開けなくなる」がある
3. パスワード空 → ボタン無効 / 誤パスワード → 「パスワードが違います」・**ログイン状態のまま**
4. 機内モードで実行 → 「削除できませんでした…」・**ログイン状態のまま**
5. 正しいパスワードで実行 → 未ログインのトップに戻る。名義・申込・共有リンクが残っていない
6. アプリを再起動 → 未ログインのまま（Keychain に残っていない）
7. Apple / Google のみのアカウントで「削除」と入力するまでボタンが無効
8. ゲスト状態のアカウントタブに削除導線が出ない

---

## 8. ハンドオフ（委譲プロンプト案）

**共通の前置き（全タスク）**: 「まず `.claude/skills/implementing-robustly/SKILL.md` を読み従うこと。契約の正は
`docs/plans/backend-domain-modules/api-contract.md` + `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` +
`docs/plans/account-deletion/api-contract-delta.md` の 3 本。ここに書かれたパス・キー・ステータスを変えないこと。」

### 8.1 T-BE1 → `nest-developer`（model: opus）

> **目的**: App Store Guideline 2.5 対応のアカウント削除 API を実装する。iOS（別エージェント）が同じ契約に対して並列実装中。
> **対象**: `/Users/yuyamorishita/オタ活アプリ/apps/api`
> **必読**: `docs/plans/account-deletion/api-contract-delta.md` §1 / `requirements.md` §1.1・§4 D1・§6.1 / `plan.md` §3
> **やること**（テスト先行 Red→Green）:
> 1. `requirements.md` §6.1 の AC-AD-01〜10・13 を失敗する `*.spec.ts` に翻訳する
> 2. `plan.md` §3.1 の表のファイルを作成・変更する（**表に無いファイルを触らない**）
> 3. 削除順序は `plan.md` §3.2 のコードブロックのとおり。**順序を変えない**
> 4. P2025 → `NOT_FOUND` 404 の写し替え（BE-6）
> 5. `auth.module.ts` には `exports: [PasswordHasher]` の 1 行だけ追加する
> **従う既存例**: `apps/api/src/auth/use-cases/change-password.use-case.ts:22-59`（パスワード照合と 401 の出し方）/ `apps/api/src/me/me.service.spec.ts:49-56`（Prisma モックの形）/ `apps/api/src/auth/auth.service.ts:251-270`（`$transaction` の書き方）
> **やらないこと**: `prisma/schema.prisma` / `app.module.ts` / `error-codes.ts` / `common/throttling/**` の変更。新エラーコードの追加。Apple トークン失効（別タスク T-BE2）
> **注意（`feedback_review_patterns.md`）**: BE-3（UseCase から Prisma を直接叩かない）/ BE-4（対象は常に Bearer の sub。ボディでユーザーを指定させない）/ BE-6（P2025 を 500 にしない）
> **完了条件**: `cd apps/api && npx tsc --noEmit && npm test && npm run build` が全緑。加えて `plan.md` §7.2 の実 DB 手順を実行し、手順 3 が 204 / 手順 4 が 404 になることを実測して報告に貼る
> **報告**: 日本語で ①変更ファイル（file:line）②実行した検証コマンドと結果（テスト件数）③§7.2 の実測ログ ④残課題

### 8.2 T-IOS1 → `swift-developer`（model: sonnet）

> **目的**: `DELETE /v1/me` を叩くための Domain / Network 層を実装する（UI は別タスク）。
> **対象**: `/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain` と `.../Packages/Network`
> **必読**: `docs/plans/account-deletion/api-contract-delta.md` §3 / `plan.md` §5.1 / `docs/plans/ios-network-integration/contract-mapping.md` §1・§2.3
> **やること**: `plan.md` §5.1 の表のファイルのみ変更。AC-AD-01-M〜05-M を先にテストへ翻訳してから実装
> **従う既存例**: `Packages/Domain/Sources/Domain/AuthStore.swift:255-268`（`signOut` の後始末）/ `Packages/Network/Sources/Network/Remote/RemoteAuthRepository.swift`（送信の形）
> **やらないこと**: `Packages/Features/**` と `meigicho/App/**` の変更。`keyEncodingStrategy` の設定。契約に無いバリデーション（パスワード長の下限など — IOS-4）
> **注意**: IOS-2（契約キーは `CodingKeys` に文字列で書く）/ IOS-5（Domain から Network を参照しない）
> **完了条件**: `xcodebuild ... build` が BUILD SUCCEEDED + `swift test`（Domain / Network）全緑
> **報告**: 日本語で ①変更ファイル（file:line）②テスト結果 ③残課題

### 8.3 T-IOS2 → `swift-developer`（model: sonnet）

> **目的**: アカウント削除の UI（導線・確認・実行後のローカルクリア）を実装する。
> **対象**: `/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Features/Sources/Features/Account`
> **必読**: `plan.md` §5.2（要件 1〜7 をすべて満たすこと）/ `requirements.md` §4 D4 の表 / `api-contract-delta.md` §3.3 の文言表
> **従う既存例**: `AccountView.swift:109-118`（ログアウトの導線と後始末）/ `PasswordChangeView`（シート形式のフォーム）
> **やらないこと**: `Packages/Domain` / `Packages/Network` / `meigicho/App` の変更。件数の表示（Q5 = A）。エクスポート導線（Q3 = A でスコープ外）
> **注意**: IOS-1・IOS-3（導線と縦串まで通して完了）/ IOS-4（仕様に無い入力制約を足さない）
> **完了条件**: `xcodebuild ... build` が BUILD SUCCEEDED。`plan.md` §7.3 の手動確認手順 1・2・7・8 を実施し結果を報告（3〜6 は BE 稼働が前提なので結合確認で実施）
> **報告**: 日本語で ①変更ファイル ②ビルド結果 ③手動確認の結果 ④残課題

### 8.4 R → `code-reviewer`（**別セッション** / model: opus）

> **差分範囲**: `apps/api/src/me/**` / `apps/api/src/auth/auth.module.ts`（+ T-BE2 実施時は `apps/api/src/auth/apple-token.revoker.ts`）/ `meigicho/Packages/{Domain,Network,Features}` の本計画分
> **観点**: rule 04 の 7 点 + `requirements.md` §1.1（削除順序が Restrict を回避しているか）+ BE-4（ownerId スコープ漏れ）+ NFR-AD-3（秘密値のログ漏れ）+ 契約 3 層の一致
> **スコープ外（指摘不要）**: エクスポート機能（Q3 = A）/ 猶予期間（Q1 で却下）/ `schema.prisma` の変更 / IAP 未実装
> **保存先**: `docs/plans/account-deletion/review.md`

---

## 9. 未確定事項の扱い（実装前チェックリスト）

- [ ] Q2（Apple トークン失効）の回答 → T-BE2 / T-IOS2b の実施可否と鍵 4 変数の準備
- [ ] Q3（エクスポート導線）の回答 → A なら `docs/08` の記述修正が T-D に含まれる
- [ ] Q6（サブスク文言の表示条件）の回答 → T-IOS2 の §5.2 要件 2
- [ ] Q1・Q4・Q5・Q7〜Q10 は推奨案で進行。回答が変わったら本 plan を planner が更新する
- [ ] `apps/api/.env.example` への Apple 鍵 4 変数の追記（ユーザー手動。エージェントは deny 設定で書けない）
