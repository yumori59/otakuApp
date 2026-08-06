# レビュー結果 — backend-domain-modules (apps/api/src 全体)

レビュー対象: `apps/api/src/**`（`health/` / `prisma/` を除く新規実装 T0〜T6）
レビュー基準: `docs/plans/backend-domain-modules/api-contract.md`（契約の正） / `requirements.md` / `plan.md` / `CLAUDE.md` ADR-009 / `.claude/rules/04-review.md` / `feedback_review_patterns.md`
実施日: 2026-08-01（実装者とは別セッション）

## 検証ゲート実行結果

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン（exit 0） |
| `cd apps/api && npm test` | 38 suites / 382 tests すべて green（1.5s） |
| `jose` 依存の除去 | `apps/api/package.json` に `jose` なし（申し送り 1 は事実） |

## レビュー結果サマリ

- 重大: 2 件
- 中: 5 件
- 軽微/提案: 10 件

---

## 重大 (Must Fix)

### 重大-1. Prisma のユニーク制約違反 (P2002) が envelope 化されず 500 になる — `CONFLICT` 409 契約違反

**主経路: `POST /v1/memberships` に既存 id を再送すると 500**

`apps/api/src/memberships/memberships.service.ts:58-79` — `create()` は `identities.assertOwned()` の後にいきなり `prisma.membership.create()` を呼び、既存 id の事前チェックが無い。
`identities.service.ts:56-61` と `applications/use-cases/create-application.use-case.ts:31-36` は同じ状況で 409 を返しており、**memberships だけ平仄が崩れている**。

再現条件:
1. `POST /v1/memberships {"id":"<UUID-A>", ...}` → 201
2. 同じボディを再送（オフライン同期のリトライ・二重タップで日常的に起きる）
3. Prisma が `P2002` を投げる → `AllExceptionsFilter`（`common/filters/all-exceptions.filter.ts:102-110`）が `HttpException` でないものを一律 `INTERNAL` 500 にする
4. 期待は `api-contract.md` §0「`CONFLICT` 409 = 既存 id への POST」

**同系統の第 2 経路: companions の再追加でも 500**

`apps/api/src/applications/applications.service.ts:253-298` — `replaceCompanions()` は `deletedAt: null` の既存行だけを `existing` として読む（258-261 行）。
一度削除した companion と同じ id を再送すると `existingIds` に無いため `create` 分岐（286-296 行）に入り、主キー重複で `P2002` → 500。

再現条件:
1. companions に id=X を含めて `POST /v1/applications` → 201
2. `PATCH /v1/applications/:id {"companions": []}` → X がソフトデリート
3. `PATCH /v1/applications/:id {"companions": [{"id": X, ...}]}`（ユーザーが取り消しを戻す普通の操作）→ 500

修正案:
- `MembershipsService.create()` に identities と同形の事前 `findUnique` → `AppError.conflict()` を入れる
- `replaceCompanions()` の `existing` 取得から `deletedAt: null` を外し、削除済み行に当たったら `deletedAt: null` で復活させる `update` にする（`ToursService.findOrCreateByName` の復活パターン `tours.service.ts:125-134` に合わせる）
- 併せて `AllExceptionsFilter` に Prisma `P2002` → `CONFLICT` 409 / `P2025` → `NOT_FOUND` 404 の写像を足すと、`MeService.updateMe`（`me.service.ts:107`、profile 行が無いと P2025 → 500）や create 系の競合レースも取りこぼさない

### 重大-2. `PATCH /v1/applications/:id` で `rep_identity_id` だけ変更すると `rep_membership_id` が別名義のまま残る（FR-AP-4 の不変条件が破れる）

`apps/api/src/applications/use-cases/update-application.use-case.ts:32-40` — membership の再検証は `if (dto.rep_membership_id)` が真のときだけ実行される。
`rep_identity_id` のみを更新した場合、既存の `repMembershipId`（= 旧名義に属する membership）が検証されずそのまま残る。

再現条件:
1. `POST /v1/applications` で `rep_identity_id = A` / `rep_membership_id = M`（M は A の FC 会員）→ 201（`create-application.use-case.ts:52-60` で不変条件を検証済み）
2. `PATCH /v1/applications/:id {"rep_identity_id": "B"}` → 200
3. 結果: 代表名義 B の申込に、名義 A の会員資格 M が紐づいたまま残る

`requirements.md` FR-AP-4 と `api-contract.md` §7 手順 4 は「`rep_membership_id` は自分の未削除 membership かつ `identity_id = rep_identity_id`」を不変条件として要求している。POST では守られ PATCH で破れるため、DB に不正状態が作れる。UI 上は「名義 B の申込に名義 A の会員番号下 4 桁」が出る。

同じ不変条件は `PATCH /v1/memberships/:id` の `identity_id` 付け替え（`memberships.service.ts:88-93`、申し送り 2）でも破れる: membership M を A→C に移すと、M を参照している既存 application（rep_identity=A）が不整合になる。

修正案（どちらか）:
- `UpdateApplicationUseCase` で `dto.rep_identity_id !== undefined && dto.rep_membership_id === undefined` のとき、`current.repMembershipId` を新 identity で再検証し、属さないなら 400（または `repMembershipId: null` にクリア）
- `MembershipsService.update()` の `identity_id` 付け替え時も、その membership を参照する application が無いことを確認するか、`repMembershipId` をクリアする
- どちらの挙動にするかは契約に無いため、`api-contract.md` §7 / §4 に 1 行追記して確定させる

---

## 中 (Should Fix)

### 中-1. 未知 kid の identity token が毎リクエスト Apple JWKS への再取得を強制する（未認証 DoS 面）

`apps/api/src/auth/apple-jwks.provider.ts:41-49` — キャッシュミス時に無条件で `keys(true)`（強制再取得）を呼ぶ。cooldown が無い。
未認証の攻撃者が `kid` をランダムにした JWT を投げ続けるだけで、リクエストごとに `appleid.apple.com` への外向き fetch（タイムアウト 5s）が発生し、レイテンシとレート制限を消費する。
`jose` の `createRemoteJWKSet` は同じ目的で `cooldownDuration`（既定 30s）を持っており、`node:crypto` 移行で落ちた唯一の実質的な機能差。

修正案: `lastForcedFetchAt` を持ち、強制再取得を 30〜60 秒に 1 回へ制限する（cooldown 中の未知 kid は `null` を返して 401）。

### 中-2. `inGracePeriod` が `plan` に関係なく無制限を与える

`apps/api/src/entitlements/entitlements.service.ts:66-72` — `if (entitlement.inGracePeriod) return true;` が `plan` 判定より前にある。
`requirements.md` FR-ID-4 / `plan.md` §3.4 は「**plus**（有効 or 猶予中）→ 無制限」と規定しており、`plan='free'` かつ `in_grace_period=true` の行は仕様上は上限 3 のはず。現状は名義・共有リンクとも無制限になる（プラン上限バイパス経路）。
`entitlements.service.spec.ts:111-120` の猶予テストは `plan: 'plus'` のみで、free + grace のケースは未検証。

修正案: `if (entitlement.plan !== 'plus') return false;` を先に評価する。テストに `plan:'free', inGracePeriod:true → 3` を追加。

### 中-3. `GET /v1/applications` のカーソルが `updated_at` 同値の行を取りこぼす

`apps/api/src/applications/applications.service.ts:67,74` — `orderBy: [updatedAt asc, id asc]` に対し、カーソル条件は `updatedAt > cursor` のみ。
`updated_at` がミリ秒まで同値の行が limit 境界をまたぐと、次ページで**まるごとスキップされる**。オフライン同期（1 TX で複数 application を作成・更新）では同値が現実的に発生する。

修正案（契約側の更新も要る）: カーソルを `"<updated_at>|<id>"` の複合にして `OR: [{updatedAt: {gt}}, {updatedAt: eq, id: {gt}}]` にする。契約は `api-contract.md` §0 / §7 を更新。今回スコープ外とするなら「同値取りこぼしの既知制約」として plan の残課題に明記する。

### 中-4. 公開共有ペイロードで同行者名がマスクされない（申し送り 4 の判断について）

`apps/api/src/public/public-share.presenter.ts:92` / `tours/tour-matrix.service.ts:106-110` — companion は `identity.displayName`（現在値）をそのまま出力する。
これは `api-contract.md` §8 マスキング表の 4 行目（「同行者: identity_id があればその identity の現在の display_name」）と `docs/03-database.md:760-762` の SQL の双方に一致しており、**契約違反ではない**。
ただし実質的な問題として、`history_visible=false` の名義は代表者としては「非公開の名義」に伏せられるのに、同じ人物が同行者として載っている行では実名（かつ参加公演）が公開リンクに出る。`docs/03-database.md:324` の「history_visible 既定 false」という設計意図（本人が明示同意した名義だけ公開）と整合しない。

対応: 実装をこのままにするなら契約に「同行者は history_visible の影響を受けない」を明記し、そうでなければ `TourMatrixInternalRow` に `companion_history_visible: boolean[]` を持たせて presenter でマスクする。**planner に判断を戻すべき項目**（実装者の独断で確定させない）。

### 中-5. 新規に必要な環境変数が `docker-compose.yml` に無く、ローカルで auth / shares が 500 になる

`docker-compose.yml:26-33` の `api.environment` には `JWT_ACCESS_SECRET` / `CORS_ORIGINS` しかない。
`plan.md` §3.7 が要求する `APPLE_CLIENT_ID` / `APPLE_ISSUER` / `APPLE_JWKS_URL` / `JWT_ACCESS_TTL_SECONDS` / `REFRESH_TTL_DAYS` / `SHARE_BASE_URL` が未追加のため、`make up` 直後に
- `POST /v1/auth/apple` → `INTERNAL` 500（`apple-token.verifier.ts:69-74`）
- `POST /v1/shares` → `INTERNAL` 500（`create-share.use-case.ts:37-43`）
となり、iOS 側の疎通確認ができない。
また `docker-compose.yml:32` の `JWT_REFRESH_SECRET` は refresh token が不透明ランダム（JWT ではない）になったため未使用。

※ `apps/api/.env.example` は本セッションの権限設定で読めなかったため未確認。plan §3.7 の追記が済んでいるかは実装者側で確認すること（**カバレッジの正直さ**）。

---

## 軽微 (Nice to Have)

1. **`assertMembershipOwned` の置き場所**（申し送り 3）— `applications/applications.service.ts:149-167` が `membership` テーブルを直接引いている。ロジックの意味論は `memberships.service.ts:128-136` の `findOwned` + `identityId` 条件と矛盾しない（ownerId・`deletedAt: null` とも一致）ので不整合は無いが、モジュール境界を越えた表アクセス。`MembershipsService.assertOwnedByIdentity()` に移して `ApplicationsModule` が `MembershipsModule` を import する形が本来の平仄（`IdentitiesService.assertOwned` の再利用と同じ形）。同様に `public/identity-summary.service.ts:37-45` も `application` テーブルを直接引いている。
2. **`PATCH /v1/memberships/:id` の `identity_id` 変更**（申し送り 2）— 所有検証（`memberships.service.ts:88-90`）が入っており `ownerId` も同一ユーザー内なので安全。契約 §4 に「PATCH で `identity_id` の付け替えを許可する」を 1 行追記して確定させること（重大-2 の副作用も併記）。
3. **CORS が GET/OPTIONS に絞られていない** — `main.ts:11-17` は全メソッド・全ルートに `CORS_ORIGINS` を許可する。`api-contract.md` §8 は「共有 Web オリジンに対して `GET, OPTIONS` のみ」。ただし `plan.md:129` が「既存の `CORS_ORIGINS` 方式を維持」と明記しているため実装は plan 準拠。契約と plan のどちらを正とするか揃えること。
4. **`expires_at` の下限が無い** — `shares/dto/create-share.dto.ts:60-65` は上限 +365 日のみ検証。過去日時を渡すと即座に無効なリンクが発行でき、しかも `countActive` に載らないので上限判定もすり抜ける。`at > Date.now()` の下限を足すのが自然。
5. **プラン上限判定に競合ウィンドウがある** — `identities.service.ts:63-75` / `create-share.use-case.ts:82-94` はいずれも count → create の間に排他が無く、同時 2 リクエストで上限 +1 まで作れる。実害は小さいが、TX 内で数えるか部分ユニーク制約を検討。
6. **ソフトデリート済み tour 名との衝突で復旧経路が無い** — `tours.service.ts:56-63` は `findUnique(ownerId_name)` が削除済み行に当たっても 409 を返す。`findOrCreateByName`（125-134 行）は同じ状況で復活させるので挙動が非対称。PATCH 側も復活扱いにするか、409 の `details` に「削除済み」を入れると UI が救える。
7. **JWT 検証時にアルゴリズムを明示していない** — `common/guards/jwt-auth.guard.ts:41-43`。`jsonwebtoken` は文字列 secret のとき HS 系に限定するので現状 alg 混同は起きないが、`algorithms: ['HS256']` を明示するとライブラリ更新に対して堅くなる。
8. **`mask_member_no` が受理・保存・返却されるだけで公開ペイロードに影響しない** — 公開レスポンスにそもそも会員番号系のキーが無い（安全側）。契約通りだが、フラグが no-op であることを契約かコードのコメントに残しておくと、後から「マスクされているはず」という誤解を防げる。
9. **未使用依存** — `package.json:36` の `uuid` は `src` から一度も import されていない（すべて `node:crypto` の `randomUUID`）。削除可。
10. **DB 実結合テストが無い** — 全 spec が Prisma モック。`nulls: 'last'` の並び、`@@unique([ownerId, name])`、TX ロールバック、P2002 の実挙動（重大-1 の根拠）はモックでは検証されていない。testcontainers か docker-compose の DB を使った smoke test を Phase B の残課題に積むこと。

---

## 良かった点

- **レイヤ規律 (ADR-009 / BE-3)**: `PrismaService` を import しているのは 12 の Service と `health.controller`（既存）のみ。Controller / UseCase からの Prisma 直叩きはゼロ。`ApplicationsService.transaction()`（`applications.service.ts:51-55`）で UseCase に Prisma を露出させずに TX を張る設計が綺麗。
- **マスキングの単一責務化 (BE-4)**: 公開ペイロードの組み立てを `public/public-share.presenter.ts` に集約し、行を spread せず契約キーのみを明示構築。`resolve-share.use-case.spec.ts:76-89,226-266` の「キー名を再帰収集して禁止キー・禁止 UUID の不在を assert する」テストは、将来の追加フィールドによる漏洩も検出できる良いテスト。`ACC-3F9A21` / `owner_id` / 内部 UUID の不在まで検証済み。
- **Apple トークン検証が本物のテストで守られている**: `auth/apple-token.verifier.spec.ts` は `generateKeyPairSync` で実鍵を作り、実署名を検証している。`alg: none`・alg 差し替え・別鍵署名・未知 kid・iss/aud/exp/sub/nonce 不一致まで網羅（18 ケース）。`node:crypto` 実装は署名検証を payload 解釈より前に行い、`APPLE_CLIENT_ID` 未設定時に aud 検証を素通しせず 500 にする（`apple-token.verifier.ts:68-74`）など、`jose` 相当のセマンティクスを満たしている（差分は中-1 の cooldown のみ）。
- **秘密情報の扱い**: refresh token / share token とも生値は DB に入らず `sha256Hex` のみ（`auth.service.ts:143`、`shares.service.ts:54`）。検索も必ずハッシュ経由（`shares.service.spec.ts:192`）。`GET /v1/shares` の presenter は `token` / `token_hash` を型レベルで持たない。
- **公開経路の棚卸しが正しい**: `@Public()` は auth 3 本 + `/health`・`/readyz` + `/public/shares/:token` のみ。`app.setup.spec.ts` が実 `AppModule` を起動して prefix exclude と envelope を検証しており、DI 配線の破綻も同時に検出できる。
- **エラー本文の同一性テスト** (`resolve-share.use-case.spec.ts:154-164`): 未知 / 失効 / 期限切れ / 期限ちょうどの 4 パターンで JSON が完全一致することを assert。存在推測を許さない設計を機械で守っている。
- **テストの受入基準トレーサビリティ**: 382 テストのほぼすべてが `AC-XXX-NN` 付きで `requirements.md` に対応。見せかけのテスト（実装をそのまま写しただけの assert）は確認した範囲で見当たらない。
- **T0〜T6 の担当分割にもかかわらず平仄が揃っている**: presenter の `toXxxResponse` 命名、`assertOwned(userId, id, tx?)` シグネチャ、ソフトデリートの冪等パターン（`findFirst` → `deletedAt` 済みなら早期 return）が全モジュールで統一されている。例外は重大-1 の memberships 409 欠落のみ。

---

## 申し送り事項への回答

| # | 実装者の申し送り | 判定 |
|---|---|---|
| 1 | `jose` → `node:crypto` の RS256 検証 | **概ね同等**。署名/alg/kid/iss/aud/exp/nonce は `jose` と同水準で、テストも実鍵で検証済み。唯一の実質差は JWKS 再取得の cooldown 欠如（**中-1**） |
| 2 | `PATCH /v1/memberships/:id` の `identity_id` 変更 | 安全性は OK（所有検証あり）。ただし既存 application との不整合を生む（**重大-2** に統合）。契約に明記すること（軽微-2） |
| 3 | `rep_membership_id` 検証を `ApplicationsService` に実装 | **不整合なし**。ownerId・`deletedAt: null` の条件は `MembershipsService.findOwned` と一致。置き場所のみ改善提案（軽微-1） |
| 4 | 同行者名はマスク対象外 | **契約どおり**（§8 表 4 行目・docs/03 §6.5 SQL とも一致）。ただし設計意図との齟齬があるため planner 判断へ差し戻し推奨（**中-4**） |
| 5 | `GET /v1/tours` / `/v1/events` に `include_deleted` 無し | **指摘なし**。契約に記載が無く、スコープ外 |

## SSOT (`feedback_review_patterns.md`) への追記提案

既存の BE-1〜BE-5 に該当しない新パターンを 1 件観測した。**修正完了後**に追記すること:

> | BE-6 | **Prisma 例外の envelope 漏れ** | `P2002`（既存 id への POST）/ `P2025`（対象行なし）が `AllExceptionsFilter` で `INTERNAL` 500 になる。契約上の `CONFLICT` 409 / `NOT_FOUND` 404 に写すか、Service 側で事前検出する。クライアント発行 UUID + オフライン再送があるため再 POST は通常運用で起きる |

## 次のアクション

1. 重大-1 / 重大-2 を修正（テスト先行: 再 POST 409・companion 再追加・`rep_identity_id` 単独変更の 3 ケースを Red から）
2. 中-1〜中-3・中-5 を修正、中-4 は planner に差し戻し
3. `npx tsc --noEmit` / `npm test` / `npm run build` を再実行のうえ再レビュー（rule 04: 重大ゼロで完了）

---

# 再レビュー結果（修正差分）

レビュー対象: 初回レビューの重大-1 / 重大-2 / 中-1 / 中-2 / 中-3 / 中-5 に対する修正差分
（`common/filters/all-exceptions.filter.ts` / `memberships/memberships.service.ts` / `applications/applications.service.ts` /
`applications/use-cases/update-application.use-case.ts` / `auth/apple-jwks.provider.ts` / `entitlements/entitlements.service.ts` /
`common/dto/pagination.dto.ts` / `docker-compose.yml` / 対応する `*.spec.ts` / `api-contract.md` / `feedback_review_patterns.md`）
実施日: 2026-08-01（実装者とは別セッション）。全体の再走査はスコープ外。

## 検証ゲート実行結果（本セッションで実行）

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン（exit 0） |
| `cd apps/api && npm test` | 40 suites / 411 tests すべて green（1.6s。前回 38/382 から +2 suites / +29 tests） |
| `cd apps/api && npm run build` | 成功（`nest build` エラーなし） |

## 再レビュー結果サマリ

- **重大: 0 件**（重大-1 / 重大-2 とも修正を確認）
- 中: 2 件（いずれも今回の修正で新たに見えた隣接ケース。初回指摘の再発ではない）
- 軽微/提案: 7 件

## 初回指摘の解消状況

| # | 判定 | 根拠（実コードを読んで確認） |
|---|---|---|
| 重大-1 (memberships 再 POST) | **解消** | `memberships.service.ts:64-70` で `findUnique({where:{id}})` → `AppError.conflict`。`identities.service.ts:55-60` と同形で平仄が取れた。削除済み id も 409（`findUnique` は `deletedAt` を見ない） |
| 重大-1 (companion 再追加) | **解消** | `applications.service.ts:287-289` の `findMany` から `deletedAt: null` が外れ、`existingIds` に削除済みも入る。`309-317` の `update` が `deletedAt: null` を書いて復活させる。`create` 分岐に落ちない。削除対象の抽出は `294-299` で `deletedAt === null` に限定しており、削除済み行に `deleted_at` を再スタンプしない |
| 重大-1 (保険の P2002/P2025 写像) | **解消** | `all-exceptions.filter.ts:43-46,117-130`。`Prisma.PrismaClientKnownRequestError` のみを対象にコード表で写像し、**メッセージは固定文字列**（`resource already exists` / `resource not found`）・`details: null`。Prisma の原文（`Unique constraint failed on the fields: (id)` 等の表・列名）はレスポンスに出ない。表に無い code（P2024 等）は INTERNAL 500 のまま＝黙って別扱いにしない。`all-exceptions.filter.spec.ts:131-187` が「本文に `Unique constraint` を含まない」「キーは 4 つだけ」まで assert しており、内部情報の漏洩は機械で守られている |
| 重大-2 (`PATCH /v1/applications/:id`) | **解消** | `update-application.use-case.ts:41-58`。分岐の抜けを個別に確認: ① `rep_membership_id` 明示 `null` → `dto.rep_membership_id === undefined` が false なので自動クリア判定に入らず、`applyUpdate`（`applications.service.ts:254-256`）が素直に null を書く＝二重処理なし ② `rep_identity_id` が現在値と同値 → `!== current.repIdentityId` で弾かれ再検証が走らない ③ `current.repMembershipId` が null → 再検証しない ④ 新名義に属していれば維持（`findMembershipOwned` の非例外版を分けたのは正しい設計。`assertMembershipOwned` の 404 セマンティクスを流用していない） |
| 重大-2 (`PATCH /v1/memberships/:id` 側) | **解消** | `memberships.service.ts:128-140`。`prisma.$transaction` のコールバック内で `tx.membership.update` → `tx.application.updateMany` の順に実行しており、**TX 外実行は無い**（`this.prisma.*` を使っている箇所はコールバック外に存在しない）。条件も `ownerId` / `deletedAt: null` / `repIdentityId: { not: nextIdentityId }` と正確で、移動先名義と一致する参照は温存する。`nextIdentityId` が null（同値 or 未指定）のときは TX を張らず単純 update に落とすので、不要な TX も張らない |
| 中-1 (JWKS cooldown) | **解消** | `apple-jwks.provider.ts:30,54-61`。`lastForcedFetchAt` を強制再取得の**前**に更新するので同時多発リクエストでも 1 回に収束。初期値 0 なので起動直後の 1 回目は通る。cooldown 中はキャッシュのみで判定し `null`（→401）を返す |
| 中-2 (`inGracePeriod`) | **解消** | `entitlements.service.ts:69-75` で `plan !== 'plus'` を最初に評価。`entitlements.service.spec.ts:122-152` に `free + grace → 3` / `free + grace + bonus → 5` / `期限切れ plus → 3` / `free + grace のシェア上限 1` を追加済み |
| 中-3 (カーソル取りこぼし) | **解消** | `applications.service.ts:67-75` が `OR: [{updatedAt:{gt}}, {updatedAt: eq, id:{gt}}]`、`91` が `formatCursor(last.updatedAt, last.id)`。`orderBy` `[updatedAt asc, id asc]` と整合。契約も `api-contract.md:20,504,509` と §9 D11 に反映済みで矛盾なし |
| 中-5 (compose の環境変数) | **解消** | `docker-compose.yml:28-40` に `JWT_ACCESS_TTL_SECONDS` / `REFRESH_TTL_DAYS` / `APPLE_CLIENT_ID` / `APPLE_ISSUER` / `APPLE_JWKS_URL` / `SHARE_BASE_URL` を追加、未使用の `JWT_REFRESH_SECRET` を削除。`src` が読む env キーを実際に列挙して照合したところ `APPLE_CLIENT_ID / APPLE_ISSUER / APPLE_JWKS_URL / CORS_ORIGINS / JWT_ACCESS_SECRET / JWT_ACCESS_TTL_SECONDS / PORT / REFRESH_TTL_DAYS / SHARE_BASE_URL` の 9 件で、compose と過不足なく一致 |
| 中-4 | 未修正（**意図どおり**。planner 判断に差し戻し中でスコープ外） |
| SSOT 追記 | 確認 | `feedback_review_patterns.md:21` に BE-6 が 1 行追記済み |

**契約文書**: `api-contract.md` §0（cursor が opaque・壊れたら 400）/ §4（membership の 409 と `identity_id` 付け替え時の自動クリア）/ §7（`rep_identity_id` 単独変更時の自動クリア・`(updated_at, id)` 複合カーソル）/ §9 D11 を確認。実装と食い違う記述は見つからなかった。

**iOS への追従**: `meigicho/Packages` は `Core / DesignSystem / Domain / Features` のみで Network/DataStore は未作成、`next_cursor` / `rep_membership` を参照するコードもゼロ。今回の契約変更に対する iOS 側の追従漏れ（IOS-2）は発生していない。

---

## 中 (Should Fix)

### 中-6. `parseCursor` が id を UUID 検証しないため、壊れたカーソルの一部が 400 ではなく 500 になる

`apps/api/src/applications/applications.service.ts:356-366` — 形式検査は「`|` の位置」「日付が parse できる」「id が空でない」の 3 点のみ。
`2026-07-31T12:05:00.000Z|not-a-uuid` は検査を通過し、`id: { gt: 'not-a-uuid' }` として `uuid` 列に到達する。
Postgres / Prisma 側で UUID 変換に失敗し `PrismaClientKnownRequestError`（P2023 系）になるが、これは `PRISMA_ERROR_MAP`（`all-exceptions.filter.ts:43-46`）に無いため **INTERNAL 500**。
`api-contract.md:20` は「壊れたトークンは `VALIDATION_ERROR` 400」と明記しているので契約違反。
同 DTO の他の UUID クエリ（`tour_id` / `event_id` / `rep_identity_id`）は `list-applications-query.dto.ts:20-30` で `@IsUUID()` 済みで、**cursor 内の id だけが素通りする唯一の経路**。
全 spec が Prisma モックのため、`applications.service.spec.ts:175-182` の「壊れた cursor は 400」テストもこのケースを踏んでいない（`'not-a-date|x'` は日付側で弾かれるケース）。

修正案: `parseCursor` に UUID 形式チェック（`class-validator` の `isUUID` か正規表現）を足し、`'2026-07-31T12:05:00.000Z|zzz'` を 400 にする spec を 1 本追加する。

### 中-7. `MembershipsService.remove()` では参照 application の `rep_membership_id` がクリアされず、同じ不変条件が別経路で破れる

`apps/api/src/memberships/memberships.service.ts:145-158` — ソフトデリートは membership 行に `deletedAt` を書くだけで、その membership を `repMembershipId` として参照している application を触らない。
`api-contract.md:484` / FR-AP-4 の不変条件は「**未削除**の自分の membership かつ `identity_id === rep_identity_id`」なので、`DELETE /v1/memberships/:id` の後は参照側が不変条件を外れる。
`update()`（`identity_id` 付け替え）では今回わざわざ TX でクリアするようにしたので、**同一サービス内で削除だけ扱いが非対称**になっている（平仄）。

影響度は重大-2 より低い（`rep_membership_id` はレスポンスにエコーされるだけで、公開共有ペイロードや matrix は参照しないことを `grep -rn "repMembership" src` で確認済み。他名義の情報が漏れる経路は無い）。ただし iOS 側は削除済み membership を持たないため、詳細画面で「会員資格が引けない申込」が黙って生まれる。

対応（どちらか。契約に書いて確定させること）:
- `remove()` を TX 化し、`update()` と同じ `application.updateMany({ repMembershipId: id, deletedAt: null }, { repMembershipId: null })` を実行する
- あるいは「削除済み membership への参照は保持する（復元時に戻る）」を `api-contract.md` §4 に明記し、`update()` 側の自動クリアとの差を意図的なものとして残す

---

## 軽微 (Nice to Have)

1. **cursor は「opaque」と契約に書いたが実体は生の `<ISO>|<uuid>`** — `applications.service.ts:351-353`。クライアントが分解・自作しないのは規約上のお願いに留まる。base64url でくるめば構造的に防げ、`|` の URL エンコード問題（iOS の `urlQueryAllowed` は `|` を含まないので %7C になる）も考えなくてよくなる。今の実装でも往復は成立するので必須ではない。
2. **`env-coverage.spec.ts` がパッケージ境界を越えてリポジトリルートを読む** — `apps/api/src/config/env-coverage.spec.ts:13-14`。判断としては **現状は許容**（守っている不変条件が「`apps/api` の実装 ↔ ルートの compose」で本質的にリポジトリ横断であり、置き場所を `apps/api` 内にした方が「実装を変えた人が落とす」ので発見が早い）。ただし ① jest の `rootDir` は `src`（`package.json:70`）で、外部ファイルへの依存は設定から見えない ② Docker のビルドコンテキストは `./apps/api`（`Dockerfile` / `docker-compose.yml:23-25`）なので、将来イメージ内でテストを回すと `ENOENT` で必ず落ちる。`existsSync(COMPOSE_PATH)` が false なら `it.skip` にする（もしくは明示メッセージ付きで落とす）ガードを 1 行入れておくと安全。
3. **P2002 / P2025 の写像はログに何も残らない** — `all-exceptions.filter.ts:76-81` は 500 以上しかログしない。`MeService.updateMe`（`me.service.ts:107`）の profile 行欠落のような「本来ありえない内部不整合」が、今後は無音の 404 になる。写像時に `logger.warn(code)` を 1 行出しておくと、契約は保ちつつ観測性を落とさない。
4. **`MembershipsService.create` の存在チェックが `ownerId` 無し** — `memberships.service.ts:65-67`。他人の membership id を当てると 409 が返る（存在オラクル）。`identities.service.ts:55-58` と同形なので平仄は取れており、id はクライアント発行 UUID v7 で総当たり不能。実害は無いが、両方直すなら同時に。
5. **memberships の TX テストが TX 内実行を厳密には検証していない** — `memberships.service.spec.ts:76` の `$transaction` モックは `cb(prisma)` とルートクライアント自身を渡すため、実装が TX 外で `application.updateMany` を呼んでも同 spec は通る（今回はソースを読んで TX 内であることを確認済み）。`update-application.use-case.spec.ts:106-110` は `tx` と `prisma` を別モックにして区別できているので、そちらに合わせると回帰を機械で守れる。
6. **§9 の差分表に今回の挙動追加が入っていない** — `api-contract.md` は D11（cursor）だけを追記した。`rep_membership_id` の自動クリア 2 種（§4 / §7）も docs/04 に無い新挙動なので、D12 として索引しておかないと docs/04 へ書き戻すときに落ちる。
7. **JWKS cooldown はプロセス内・全 kid 共通** — `apple-jwks.provider.ts:42`。Cloud Run で N インスタンスなら実効レートは N 倍、また 1 つの未知 kid が 30 秒間ほかの未知 kid の再取得も止める。DoS 面の縮小という目的には十分だが、plan の残課題に一行残すと後任が驚かない。
8. **`apps/api/.env.example` の追従は本セッションでも未確認**（権限設定で読めない）。`docker-compose.yml` は `env-coverage.spec.ts` で機械的に守られるようになったが、`make api-dev`（ホスト実行）が使う `.env.example` は同じ保護下に無い。実装者側で 9 キーが揃っているか確認すること（**カバレッジの正直さ**）。

---

## 良かった点

- **修正が「対症」ではなく経路ごと閉じている**: 重大-1 は ① memberships の事前 409 ② companion の復活 ③ フィルタでの P2002/P2025 写像の 3 段構えで、Service を通らない経路（レース）まで契約 envelope に収まるようになった。しかも写像は**固定メッセージ + `details: null`** で、Prisma 原文のテーブル名・カラム名を漏らさない設計を spec で固定している。
- **自動クリアの分岐が過不足ない**: `update-application.use-case.ts:41-58` は「明示 null」「同一 identity」「元々 null」「新名義に属する」の 4 ケースをすべて no-op に落としており、余計な `membership.findFirst` を撃たない。`findMembershipOwned`（非例外版）を `assertMembershipOwned` から分離したのも、404 セマンティクスの流用を避けた正しい判断。
- **TX 境界が正しい**: `MembershipsService.update` は `identity_id` が実際に変わるときだけ `$transaction` を張り、`membership.update` と `application.updateMany` を同一 TX に収める。BE-3（Prisma 直叩き）も維持（Controller / UseCase から Prisma 参照なし、`ApplicationsService.transaction()` 経由）。
- **テストが見せかけでない**: 追加された 29 テストは、いずれも修正前の実装で確実に落ちる assert になっている（例: `update-application.use-case.spec.ts:223-226` は `data` の完全一致で `repMembershipId: null` を要求、`applications.service.spec.ts:141-147` は `where.updatedAt` が undefined であることまで確認、`all-exceptions.filter.spec.ts:152` は本文に Prisma 原文が混ざらないことを確認）。「同値なら再検証しない」「削除済みに再スタンプしない」といった**やらないことの assert** まで書かれているのは質が高い。
- **`env-coverage.spec.ts` は中-5 を「二度と起きない」形にした**: 単に compose を直すのではなく、`src` の `config.get('X')` / `process.env.X` を静的走査して compose と突き合わせ、逆方向（compose に余分なキーが残る）も検査している。実際に `JWT_REFRESH_SECRET` の残骸をこのテストが排除している。
- **契約文書と SSOT の更新が同時に入っている**: `api-contract.md` §0/§4/§7/§9(D11) と `feedback_review_patterns.md` BE-6。実装だけ直して契約が古いまま、という最も事故りやすいパターンを回避できている。
- **既存 T0〜T6 の回帰なし**: 40 suites / 411 tests green、`tsc --noEmit` クリーン、`nest build` 成功。cursor を使うのは applications のみ（`grep` 済み）で、他モジュールのページングに波及していない。

## 判定

**重大 0 件**。rule 04-review.md の完了条件（重大ゼロ）を満たす。
中-6 / 中-7 は今回の修正で新たに見えた隣接ケースであり、初回指摘の再発ではない。コミットを止める必要は無いが、中-6 は契約（§0）との明確な不一致なので次の差分で拾うこと。

## 追補（オーケストレーターによる中-6 / 中-7 修正）

再レビュー完了直後、以下 2 件をオーケストレーター自身が直接修正した（軽微な機械的修正のため新規エージェント委譲は行わず、Red→Green で対応）。

- **中-6**: `apps/api/src/applications/applications.service.ts` の `parseCursor` に UUID 形状チェック（`UUID_SHAPE_REGEX`。BE-1 に倣いバージョンは検証しない）を追加。`applications.service.spec.ts`「AC-APP-16 壊れた cursor は VALIDATION_ERROR 400」に `2026-07-31T12:05:00.000Z|not-a-uuid` のケースを追加
- **中-7**: `apps/api/src/memberships/memberships.service.ts` の `remove()` を `$transaction` 化し、`update()` と同じ `application.updateMany({ ownerId, repMembershipId: id, deletedAt: null }, { repMembershipId: null })` を実行するよう修正。`memberships.service.spec.ts` に検証テストを追加

検証: `npx tsc --noEmit` クリーン / `npm test` 40 suites・**412 tests** 全緑 / `npm run build` 成功。軽微項目（`.env.example` 未確認、cursor の base64url 化、§9 D12 追記など）は残課題として残す。
