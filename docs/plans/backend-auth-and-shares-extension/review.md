# レビュー結果 — backend-auth-and-shares-extension

レビュー対象: 今回の拡張差分のみ（`auth/`・`mail/`・`common/throttling/`・`common/errors/error-codes.ts`・`entitlements/`・`shares/`・`public/`・`me/me.service.ts`・`prisma/schema.prisma`・`app.setup.ts`・`docker-compose.yml`）
レビュー基準: `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md`（契約の正）/ `requirements.md` / `plan.md` / 基底契約 `docs/plans/backend-domain-modules/api-contract.md` / `CLAUDE.md` ADR-009 / `.claude/rules/04-review.md` / `feedback_review_patterns.md` BE-1〜BE-6
実施日: 2026-08-03（実装者とは別セッション）

## 検証ゲート実行結果

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン（exit 0・出力なし） |
| `cd apps/api && npm test` | 64 suites / 684 tests すべて green（1.8s） |
| `cd apps/api && npm run build` | 成功（`nest build` exit 0） |

補足: `apps/api/.env.example` は権限設定により本セッションから読めなかったため、契約 §0 が求める `GOOGLE_*` / `RESEND_*` の追記は**未検証**（`docker-compose.yml` 側は `env-coverage.spec.ts` により機械的に担保されていることを確認済み）。

## レビュー結果サマリ

- 重大: 0 件
- 中: 4 件
- 軽微/提案: 8 件

---

## 重大 (Must Fix)

**なし。** 依頼された重点確認 16 項目はいずれも契約どおりに実装されている（末尾「重点確認項目の判定」参照）。

---

## 中 (Should Fix)

### 中-1. リセットコードのログ出力条件が fail-open — `NODE_ENV` 未設定で 8 桁コードが Cloud Logging に残る

`apps/api/src/mail/resend.mail.sender.ts:26-39`

```ts
const isProduction = process.env.NODE_ENV === 'production';
if (!apiKey) {
  if (isProduction) { throw new AppError(ErrorCode.INTERNAL, 'mail sender is not configured'); }
  this.logger.warn(input.text);   // ← 本文＝8 桁コードそのもの
  return;
}
```

判定が「production **でなければ** 出す」という deny-list になっている。`NODE_ENV` が未設定・`staging`・`prod`（typo）のいずれでも平文コードがログに落ちる。
`apps/api/Dockerfile:15` が `ENV NODE_ENV=production` を持つので既定は安全だが、Cloud Run 側で `--set-env-vars` を使うと image の ENV が消えるケースがあり、`RESEND_API_KEY` 未設定と重なると即座に成立する（コードさえ読めればアカウント乗っ取りが可能なので影響は大きい）。

修正案: allow-list に反転する（`['development','test'].includes(nodeEnv)` のときだけログ出力、それ以外は throw）。
あわせて `process.env` 直読みではなく `ConfigService` に揃える — 現状 `env-coverage.spec.ts:17` が `NODE_ENV` を `NOT_REQUIRED_IN_COMPOSE` に入れているため、この env に関しては機械ゲートが効かない。

### 中-2. `share-item-key.ts` の「不変条件」コメントが事実に反する（HMAC 鍵は共有先が計算できる）

`apps/api/src/public/share-item-key.ts:6` / `apps/api/src/public/share-write.ts:17`

> 鍵は `share_links.token_hash`（sha256 hex・**クライアントには出ない高エントロピー値**）

`token_hash = sha256Hex(token)`（`apps/api/src/shares/shares.service.ts:104-107`）なので、**共有リンクを持つ相手は鍵を自力で計算できる**。「クライアントには出ない」は誤り。

現時点で実害は無い。`item_key = HMAC(key, "item:" + application.id)` の message 側が `randomUUID()` 由来の 122bit で推測不能なため、鍵を知っていても内部 UUID の復元も別行の `item_key` / `rev` の偽造もできない（依頼の観点 3 は満たされている）。
問題は前提の記述で、「鍵は秘密」という誤った不変条件を信じて将来この関数を**推測可能な message**（公演の連番・index・会員番号・account_id 等）に流用すると、その瞬間に共有先が任意のハンドルを偽造できるようになる。

修正案: コメントを実態（「鍵はリンク保持者に既知。安全性は message = 推測不能な UUID に依存する」）へ書き換える。より堅くするなら鍵を `hmac(SERVER_SECRET, token_hash)` に一段挟む。

### 中-3. `POST /v1/auth/login` が未認証のまま高コスト scrypt を無制限に誘発できる

`apps/api/src/auth/password.hasher.ts:29`（`N=32768, r=8, p=3`）+ `apps/api/src/auth/use-cases/login-with-email.use-case.ts:29-34`

`verify()` は AC-EP-09 のため**ユーザーが存在しなくても必ず 1 回 scrypt を回す**。実測（node 直叩き・本機）:

- 単発: **約 370ms**
- 8 並列: 259ms・RSS 増 **+129MiB**（`maxmem` 宣言値は 97MiB/回）

レート制限は `emailTracker`（正規化 email 単位・10 回/5 分）だけなので、**email を毎回変えれば上限に一切かからない**（`trackers.ts:1-4` のコメントどおり IP は意図的に使っていない）。数十並列で Cloud Run インスタンスの CPU とメモリを飽和させられる。

Redis バックエンドのレート制限は明示的にスコープ外（`requirements.md:328`）なので実装漏れではないが、**「p=3 前提で Cloud Run の memory / max-concurrency をサイジングする」判断を `infra/` かロードマップに残すこと**を推奨。パラメータを下げるなら OWASP 推奨の `N=2^17, r=8, p=1` 系への移行も選択肢（`needsRehash` があるので移行コストは低い）。

### 中-4.〔契約由来〕メールアドレスを知る第三者がパスワードリセットを継続的に妨害できる

`apps/api/src/auth/auth.service.ts:321-337` + `apps/api/src/auth/reset-code.generator.ts:7`（実装は契約 §1 どおり）

`recordResetAttempt()` は「そのユーザーの最新の有効コード」の `attempt_count` を増やし、5 回でそのコードを `used_at` にして失効させる。攻撃者はカウンタの持ち主ではないので、**被害者の email さえ知っていれば、被害者が受け取ったばかりのコードを誤コード 5 回送信で殺せる**。

再現条件:
1. 被害者が `POST /v1/auth/password/reset-request`（3 回/15 分）でコードを受信
2. 攻撃者が `POST /v1/auth/password/reset` に被害者の email + でたらめな 8 桁を 5 回送る（`reset-submit` は 10 回/15 分 = 1 ウィンドウで 2 本殺せる）
3. 被害者が正しいコードを入力しても `AUTH_RESET_CODE_INVALID` 401。以後 2 を繰り返すだけでアカウント回復を無期限に妨害できる

契約 §1「誤コード 5 回で当該コードを失効させる」に忠実な実装なので**実装の瑕疵ではない**が、アカウント回復手段が他に無いためリスクとして計上する。対応するなら「試行回数をコードではなく送信元に紐付ける」「失効ではなく一定時間のクールダウンにする」など契約側の見直しが要る。

---

## 軽微 / 提案 (Nice to Have)

### 軽微-1. PATCH の判定順序 ④（ボディ 400）は実 HTTP 経路ではグローバル `ValidationPipe` が①より先に走る

`apps/api/src/public/use-cases/update-share-item.use-case.ts:57-68` / `apps/api/src/app.setup.ts:21-27`

契約 §4 の表は「①token 404 → ④body 400」の順だが、Nest では pipe が handler より前なので**未知トークン + 不正ボディは 404 ではなく 400** になる。
情報漏洩は無い（ボディ不正の 400 はトークンの有効・無効に依らず同一）。use-case 内部の ④→⑤ 順序は契約どおり実装され spec でも検証されている（`update-share-item.use-case.spec.ts:292`）。契約文に「④はガード/パイプ段で先行しうる」旨を注記するのが正確。

### 軽微-2. `editable` の「先頭 N 公演」の母集合が発行時上限判定と食い違う

`apps/api/src/public/share-write.ts:35-48` は **申込のある公演だけ**を行順で並べて先頭 N を取る（spec も「行順の先頭 3 公演」と表記: `share-write.spec.ts:69`）。
一方、発行時の上限判定 `SharesService.countTourEvents`（`apps/api/src/shares/shares.service.ts:133-137`）は**申込ゼロの公演も数える**。

食い違いが観測できる例（free・N=3、日付順に E1 は申込 0、E2/E3/E4 は申込あり）:
- 契約 FR-SW-3c を「全公演の先頭 3 件」と読むと editable は E2・E3
- 実装では E2・E3・E4 がすべて editable

編集可能な公演数が N を超えることは無いので上限突破ではない。どちらの解釈が正かを契約 §4 に明記したい。

### 軽微-3. PATCH の `ValidationPipe` 400 には `X-Robots-Tag` が付かない

`apps/api/src/public/public.controller.ts:57` — ヘッダをハンドラ内で立てているため、pipe 段で弾かれた 400 には付かない。GET は 404 もハンドラ内で発生するので付く（`public.controller.spec.ts:126` で検証済み）。実害は小さいが、GET/PATCH で挙動が揃っていない。

### 軽微-4. `APPLE_ISSUER` と `GOOGLE_ISSUER` で空文字の扱いが揃っていない

- `apps/api/src/auth/google-token.verifier.ts:89-90`: `configured ? [configured] : DEFAULT`（truthy 判定 — `docker-compose.yml:42` の `GOOGLE_ISSUER: ""` を正しく「未設定」と解釈する）
- `apps/api/src/auth/apple-token.verifier.ts:52-53`: `?? DEFAULT_APPLE_ISSUER`（nullish 判定 — `APPLE_ISSUER: ""` を渡すと `issuers = ['']` になり**全 Apple トークンが 401**）

現状の compose は `APPLE_ISSUER` に実値を入れているので顕在化しないが、Google 側に合わせるのが安全。

### 軽微-5. `UserThrottlerGuard` のガード順序に回帰検知の口が無い

`apps/api/src/auth/auth.controller.spec.ts:101-110` は `req.user` を middleware で差し込むため、本番の「グローバル `JwtAuthGuard`（`app.module.ts:47`）→ ルートの `UserThrottlerGuard`」という実行順を検証していない。
順序自体は `@nestjs/core` の `ContextCreator.createContext`（global → class → method の順に結合）で成立していることを確認済み。ただし将来 `ThrottleAuthUser()` をクラスに移す等でこれが崩れると、`userTracker` が空文字を返し**全ユーザーが 1 バケツ（10 回/5 分）を共有**する。`POST /v1/auth/password` の 429 テストが `auth.controller.spec.ts` に無いのも合わせて補いたい。

### 軽微-6. tracker が取れないリクエストが空文字バケツを共有する

`apps/api/src/common/throttling/trackers.ts:19-22, 31-33` — `body.email` が無い / 文字列でない場合 tracker は `''`。ガードはパイプより先に走るので、`VALIDATION_ERROR` 400 になるはずのリクエストが先にカウントされ、10 回/5 分を超えると以後 400 ではなく 429 になる。実害は小さいが、tracker を解決できないときは throttle をスキップする方が素直。

### 軽微-7. 再ハッシュ保存の失敗がログイン全体を 500 にする

`apps/api/src/auth/use-cases/login-with-email.use-case.ts:37-42` — 認証自体は成功しているのに `updatePasswordHash` が失敗すると 500 を返す。best-effort（catch してログのみ）にした方が可用性が高い。

### 軽微-8. `docs/04-api.md` へ本差分が未反映

`docs/04-api.md`（714 行）に `auth/google` / `auth/register` / `auth/login` / `auth/password` / `password/reset*` / `item_key` / PATCH のいずれも登場しない。契約差分 §5 が「実装後に `docs/04-api.md` へ反映する」としている残課題。iOS 追従の前に片付けたい。

---

## 良かった点

- **判定順序が実コードでもテストでも契約どおり**。`update-share-item.use-case.ts:57-98` は ①token → ②permission → ③scope → ④body → ⑤item_key → ⑥editable → ⑦rev を素直な直線で書いており、`update-share-item.use-case.spec.ts` に順序ごとの describe が並ぶ。特に「read リンクと `editable:false` が同一の 403 本文」「プラン超過と非公開名義でエラー本文が完全一致（spec:369）」「4 パターンの `SHARE_INVALID` 本文が完全一致（spec:222）」を **`toEqual` で本文まで比較**しており、理由を区別しない要件が回帰検知できる形になっている。
- **`editable` を発行時ではなく毎回評価**（`resolve-share.use-case.ts:81-108` / `update-share-item.use-case.ts:124-133` が同じ `EntitlementsService.shareWriteEventLimit` を叩く）。プランのダウングレード・公演追加に自動追従する契約要件を、閲覧経路と更新経路の両方で満たしている（依頼の観点 15）。
- **パスワードハッシュの実装が堅い**。`scrypt` のパラメータをハッシュ文字列に埋め、`needsRehash` でログイン時に自動移行。`verify()` はユーザー不在・破損ハッシュでも `DUMMY_SALT`/`DUMMY_KEY` で同じ計算量を消費してから false を返し、比較は長さチェック + `timingSafeEqual`。`parseParams` が 2 のべき乗でない N を弾いて scrypt の例外化を防いでいるのも良い。
- **リセットコードが平文で残らない**。`resetCodeHash = sha256(userId + ':' + code)` のみを保存（`reset-code.generator.ts:24-26`・`code_hash` は `@unique`）、発行時に旧コードを同一 TX で失効（`auth.service.ts:281-294`）、成立時は 1 TX で パスワード更新 + 全コード失効 + refresh 全件失効 + 新 refresh 発行（`auth.service.ts:352-374`）。コードは `randomInt` 生成で `Math.random` を使っていない。
- **マスキングが 1 箇所に集約されたまま拡張されている**。`public-share.presenter.ts` は read/write ともに行を spread せず契約キーだけを明示構築し、write の 3 キー計算は `share-write.ts` に分離。read 経路では annotator を作らない（`public-share.presenter.ts:96-100`）ので 3 キーが混入する経路自体が存在しない。`update-share-item.use-case.ts:153-166` の応答も同じ presenter を通す。
- **BE-2（enum 黙殺）が全経路で守られている**。`permission` は DTO の `@IsIn`(`create-share.dto.ts:107`) と use-case の `resolvePermission`(`create-share.use-case.ts:131-143`) の二重防御。DB 側の未知 `permission` も read に落とさず INTERNAL 500（`resolve-share.use-case.ts:86-88`）、PATCH では write 以外を一律 403（`update-share-item.use-case.ts:62`）。`status: null` を `@IsOptional()` ではなく `@ValidateIf` で弾いている点（`update-share-item.dto.ts:53`）も正確。
- **BE-3 / BE-4 が拡張後も崩れていない**。Prisma に触るのは `AuthService` / `SharesService` / `SharedApplicationsService` / `EntitlementsService` / `MeService` / `TourMatrixService` のみ（Controller・UseCase からの直叩きは grep で 0 件）。`SharedApplicationsService` の全クエリが `link.ownerId` でスコープされ、spec:560 でも検証されている。
- **Apple / Google の OIDC 検証を `oidc/` に切り出した際に検証強度が落ちていない**。`alg` は RS256 固定、`kid` 必須、`iss`/`aud`/`exp`/`nonce` を検証、`aud` の比較は `timingSafeEqual`、未知 kid の強制再取得に 30s cooldown（`remote-jwks.provider.ts:46-59` — 未認証者が外向き fetch を強制できない）。`GOOGLE_CLIENT_IDS` 未設定を 500 にして `aud` 検証を素通ししない設計も良い。
- **アカウント統合しない設計が徹底されている**。`apple_sub` / `google_sub` / `email_normalized` はそれぞれ独立した `@unique` で、`findOrCreateGoogleUser` は `email_normalized` を書かない。`GET /v1/me` の `auth_providers` も `email` 列ではなく `password_hash` で判定（`me.service.ts:187-197`）し、順序も apple→google→email 固定。`me.service.spec.ts:119-174` が 6 パターンを網羅している。
- **`P2002` の扱いが BE-6 に沿っている**。`isUniqueViolationOn`（`auth.service.ts:497-510`）が Prisma のバージョン差（`apple_sub` / `appleSub` / `users_apple_sub_key`）を吸収し、同時初回サインインを 500 ではなく「先に作られた行を読み直す」に写す。email は `EMAIL_ALREADY_REGISTERED` 409。
- 契約の細部（`id_token` vs `identity_token` / register だけ 201 / reset-request は 202 + 空ボディ / `edit_count`・`last_edited_at` の追加のみ / `identity_summary` も `permission:"read"` を持つ / `errorCodeFromStatus` の 429 → `RATE_LIMITED`）がすべて一致。`app.setup.ts:11` の PATCH ルート exclude も入っている。
- 既存 412 テストは壊れていない（64 suites / 684 tests all green、既存 spec の `toEqual` も `permission` 追加に合わせて更新済み）。

---

## 重点確認項目の判定

| # | 観点 | 判定 |
|---|---|---|
| 1 | scrypt のソルト・パラメータ・`timingSafeEqual` | OK（16B ランダムソルト / N=2^15,r=8,p=3 / 長さ一致 + `timingSafeEqual` / 不在時もダミーで同計算量）。負荷面は 中-3 |
| 2 | リセットコードの平文非保存・TTL・試行上限・失効 | OK（`sha256(userId+':'+code)` のみ / 15 分 / 5 回 / 使用後・発行時に旧コード失効）。妨害リスクは 中-4 |
| 3 | `item_key`/`rev` から UUID・`updated_at` を逆算できないこと | OK（HMAC 一方向 + message が 122bit UUID）。ただし鍵の秘匿性に関するコメントが誤り → 中-2 |
| 4 | PATCH の判定順序（①〜⑧） | use-case 内は契約どおり・spec で検証済み。④と⑧は実 HTTP 経路で①より先行 → 軽微-1（漏洩なし） |
| 5 | 公開ペイロードのマスキング | OK（内部 UUID / owner_id / account_id / token_hash / 会員番号なし。read 経路と同一の presenter、spec:505 で検証） |
| 6 | アカウント統合しない設計 | OK（3 識別子が独立。意図せぬ統合パスなし） |
| 7 | レート制限の tracker（IP を使っていない） | OK（email / userId / token。`generateKey` にクラス名+ハンドラ名が入るのでルート間で混ざらない）。空文字バケツは 軽微-6 |
| 8 | 401 メッセージの固定文字列 | OK（`CREDENTIALS_INVALID_MESSAGE` / `RESET_CODE_INVALID_MESSAGE` を定数共有。change-password も同一文字列を import） |
| 9 | `POST /v1/auth/google` のキーが `id_token` | OK（`google-sign-in.dto.ts:9`） |
| 10 | register が 201 | OK（`auth.controller.ts:67`） |
| 11 | reset-request が常に 202・ボディ無し | OK（`auth.controller.ts:95` + `Promise<void>`。送信失敗も catch して 202 維持） |
| 12 | `permission` 未知値が 400 | OK（`@IsIn` + use-case 側の二重防御） |
| 13 | `auth_providers` が apple→google→email / password_hash ベース | OK |
| 14 | Controller/UseCase からの Prisma 直叩き | 無し（ADR-009 準拠） |
| 15 | `shareWriteEventLimit` を閲覧・更新のたびに評価 | OK。母集合の解釈差は 軽微-2 |
| 16 | 既存テストの非破壊 | OK（684 tests all green） |

---

## 追補（オーケストレーターによる中-1 / 中-2 修正）

レビュー直後、指摘のうち2件をオーケストレーター自身が直接修正した（軽微な機械的修正のため新規エージェント委譲は行わず、Red→Green で対応）。

- **中-1**（リセットコードのログ fail-open）: `apps/api/src/mail/resend.mail.sender.ts` の `NODE_ENV` 判定を deny-list（`=== 'production'` のときだけ fail closed）から **allow-list**（`development`/`test` のときだけログ出力を許可し、それ以外はすべて fail closed）に反転。`resend.mail.sender.spec.ts` に `NODE_ENV` 未設定・`staging`・typo の3ケースで fail closed になることを確認するテストを追加
- **中-2**（`share-item-key.ts` のコメント誤り）: 「鍵は token_hash（クライアントに出ない高エントロピー値）」という誤った不変条件の記述を修正し、実際の安全性根拠（鍵ではなくメッセージ側の application.id が推測不能であることに依存）と将来の転用時の注意を明記

**未対応**（スコープ外として残す。契約・設計判断であり実装の瑕疵ではない）:
- 中-3（未認証 scrypt 誘発による負荷）: Redis バックエンドのレート制限は`requirements.md`で明示的にスコープ外。Cloud Runのサイジング判断として残す
- 中-4（リセットコード5回誤りによる第三者妨害）: 契約§1どおりの実装。アカウント回復手段の追加は別計画
- 軽微8件: 対応しない

検証: `npx tsc --noEmit` クリーン / `npm test` 64 suites・**685 tests** 全緑 / `npm run build` 成功。
