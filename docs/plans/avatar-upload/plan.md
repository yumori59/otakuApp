# plan — avatar-upload

アカウント本人のプロフィールアイコン（アバター画像）の設定・削除。BE（NestJS）+ iOS + DB + インフラ（GCS / Terraform / CI）。

- 起票: 2026-10-27 / aidlc-planner
- 入力: `requirements.md`（FR / NFR / E / AC）・`api-contract-delta.md`（**契約の正**）・`storage-design.md`・`db-schema-and-deploy.md`・`questions-requirements.md`
- **着手条件**: `questions-requirements.md` の Q0 / Q3 / Q5 にユーザーの `[Answer]` が入っていること。未回答のまま進める場合は [推奨] で実装し、ドラフト PR 上で確認を取る（PR はマージしない）
- ロードマップ: `docs/09-roadmap.md` に**未計上**（Phase 外）かつ `docs/01` R5-5「画像を使わない」と衝突する。Q0-A（本人のみ・名義は対象外）を前提に T-DOC で docs を更新する

---

## 1. 影響範囲（層チェックリスト）

| 層 | ファイル | 変更 |
|---|---|---|
| DB | `apps/api/prisma/schema.prisma` | `UserAvatar` モデル新設 + `User.avatar` リレーション |
| BE common | `apps/api/src/common/errors/error-codes.ts`（+ spec） | `PAYLOAD_TOO_LARGE` / `UNSUPPORTED_MEDIA_TYPE` / `SERVICE_UNAVAILABLE`。`errorCodeFromStatus` に 413/415/503 |
| BE me | `apps/api/src/me/avatar/avatar-image.processor.ts`（新規） | sharp による検証・再エンコード |
| | `apps/api/src/me/avatar/avatar.storage.ts`（新規） | 抽象クラス `AvatarStorage`（DI トークン。`MailSender` と同じ形） |
| | `apps/api/src/me/avatar/gcs-avatar.storage.ts`（新規） | `@google-cloud/storage` 実装（ADC / `GCS_API_ENDPOINT`） |
| | `apps/api/src/me/avatar/avatar.service.ts`（新規） | `user_avatars` の読み書き（P2021 / P2003 の写し替え） |
| | `apps/api/src/me/use-cases/upload-avatar.use-case.ts`（新規） | アップロード手順・補償削除 |
| | `apps/api/src/me/use-cases/delete-avatar.use-case.ts`（新規） | 削除手順 |
| | `apps/api/src/me/use-cases/delete-me.use-case.ts` | 退会時のオブジェクト削除（ベストエフォート） |
| | `apps/api/src/me/me.service.ts` | `MeProfileView.avatar_url`、`getMe` で `AvatarService` から URL を取得 |
| | `apps/api/src/me/me.controller.ts` | `PUT /me/avatar`（`FileInterceptor`）/ `DELETE /me/avatar` |
| | `apps/api/src/me/me.module.ts` | providers 追加（`AvatarStorage` → `GcsAvatarStorage`） |
| BE deps | `apps/api/package.json` / `package-lock.json` | `sharp`・`@google-cloud/storage`、dev: `@types/multer` |
| BE env | `docker-compose.yml`、`apps/api/.env.example` | `AVATAR_BUCKET` / `AVATAR_PUBLIC_BASE_URL` / `GCS_API_ENDPOINT`、`gcs` サービス、`infra/fake-gcs/data/meigicho-avatars-local/.keep` |
| インフラ | `infra/terraform/{storage.tf(新規),apis.tf,cloud_run.tf,outputs.tf,terraform_deployer.tf,README.md}` | `storage-design.md` §2 |
| CI | `.github/workflows/deploy-api.yml` | `db-schema` ジョブ（`db-schema-and-deploy.md` §3.1） |
| iOS Core | `Packages/Core/Sources/Core/AvatarImageEncoder.swift`（新規）+ `CoreTests` | 端末側の正方形 512 JPEG 変換 |
| iOS DesignSystem | `Components/AvatarView.swift`・`Components/FormComponents.swift`（`ProfileCard`） | `imageURL` / `size` 追加、`ProfileCard.avatarURL` |
| iOS Domain | `Models/AccountModels.swift`・`Repositories/Repositories.swift`・`ProfileStore.swift`・`AppError.swift`・`Preview/InMemoryRepositories.swift` + `DomainTests`（`FakeProfileRepository`） | `avatarURL`、upload/delete、エラー 3 種 |
| iOS Networking | `DTO/MeDTO.swift`・`Endpoint.swift`・`MultipartFormData.swift`（新規）・`Remote/RemoteProfileRepository.swift` + `NetworkingTests` | `avatar_url` デコード、multipart 送信 |
| iOS Features | `Account/AccountView.swift`・`Account/AvatarPickerSection.swift`（新規）・`Home/HomeView.swift` | 選択・プレビュー・送信・削除、ホームの入口表示 |
| docs | `docs/01`・`02`・`03`・`04`・`05`・`06`・`08`・`09`、`docs/plans/STATUS.md` | T-DOC |

**変更しないもの**: `app.module.ts`（`MeModule` 内で完結）、`auth/**`、`shares/**`、`MeService.deleteAccount` の削除順序、`secrets.tf`、`docker-entrypoint.sh`、SwiftData（DataStore）・同期エンジン（アバターは同期対象外。`GET /v1/me` のみが正）。

---

## 2. タスク一覧と依存関係

| ID | 内容 | 担当 | 依存 |
|---|---|---|---|
| T-BE1 | スキーマ + `prisma generate` + ローカル `db push` + `migrate diff` で SQL 確定（`db-schema-and-deploy.md` §1.3 を実出力で更新） | nest-developer | — |
| T-BE2 | エラーコード 3 種と `errorCodeFromStatus` | nest-developer | — |
| T-BE3 | 依存追加（`sharp`・`@google-cloud/storage`・`@types/multer`）+ `AvatarImageProcessor` | nest-developer | — |
| T-BE4 | `AvatarStorage` / `GcsAvatarStorage` + compose（`gcs` サービス・env 3 つ）+ `.env.example` | nest-developer | T-BE3（package.json を同一担当で直列） |
| T-BE5 | `AvatarService` + `MeService.getMe` に `avatar_url` | nest-developer | T-BE1, T-BE2 |
| T-BE6 | UseCase 2 本 + Controller 2 ルート + `DeleteMeUseCase` 追従 + module 登録 | nest-developer | T-BE2〜5 |
| T-INFRA1 | Terraform（`storage-design.md` §2） | nest-developer（または人） | — |
| T-CI1 | `deploy-api.yml` に `db-schema` ジョブ（Q5 = A のとき） | nest-developer（または人） | — |
| T-IOS1 | Networking + Domain（契約 §5） | swift-developer | 契約確定（本書の時点で確定） |
| T-IOS2 | Core `AvatarImageEncoder` | swift-developer | — |
| T-IOS3 | DesignSystem `AvatarView` / `ProfileCard` 拡張 | swift-developer | — |
| T-IOS4 | Features（`AccountView`・`AvatarPickerSection`・`HomeView`） | swift-developer | T-IOS1〜3 |
| T-DOC | docs 更新（§5） | planner / 任意 | — |
| R | レビュー | code-reviewer（**別セッション**） | 全タスク |

```text
T-BE1 ─┐
T-BE2 ─┼─ T-BE5 ─ T-BE6 ─┐
T-BE3 ─ T-BE4 ───────────┘ │
T-INFRA1 ──────────────────┤
T-CI1 ─────────────────────┤
T-IOS1 ─┐                  ├─ R
T-IOS2 ─┼─ T-IOS4 ─────────┤
T-IOS3 ─┘                  │
T-DOC ─────────────────────┘
```

---

## 3. 並列実行可能なタスク

契約（`api-contract-delta.md`）は本書の時点で確定しているので、**BE と iOS は同時に走らせてよい**（rule 03）。

| 波 | 同時に走らせるもの | 備考 |
|---|---|---|
| 波 1 | **[BE チェーン: T-BE1〜T-BE6（1 セッション内で直列）]** ‖ **[T-INFRA1 + T-CI1]** ‖ **T-IOS1** ‖ **T-IOS2** ‖ **T-IOS3** ‖ **T-DOC** | BE は `me/**` と `package.json` に集中するため 1 エージェントに直列で持たせる（T-BE1/2/3 は同セッション内で順不同可） |
| 波 2 | **T-IOS4** | T-IOS1〜3 の公開 API に依存 |
| 波 3 | **R**（BE / iOS / インフラを集約して 1 回） | 実装が並列でもレビューは集約（rule 03） |

### 3.1 同時に触らせないファイル（所有表）

| ファイル | 所有タスク |
|---|---|
| `apps/api/prisma/schema.prisma` | T-BE1 |
| `apps/api/package.json` / `package-lock.json` | T-BE3 |
| `apps/api/src/common/errors/error-codes.ts`（+ spec） | T-BE2 |
| `apps/api/src/me/**` | T-BE3〜T-BE6（同一セッション） |
| `docker-compose.yml` / `apps/api/.env.example` / `infra/fake-gcs/**` | T-BE4 |
| `infra/terraform/**` | T-INFRA1 |
| `.github/workflows/deploy-api.yml` | T-CI1 |
| `meigicho/Packages/{Networking,Domain}/**` | T-IOS1 |
| `meigicho/Packages/Core/**` | T-IOS2 |
| `meigicho/Packages/DesignSystem/**` | T-IOS3 |
| `meigicho/Packages/Features/**` | T-IOS4 |
| `docs/0*.md` / `docs/plans/STATUS.md` | T-DOC |

---

## 4. 各タスクの詳細

### 4.1 T-BE1 スキーマ

1. `db-schema-and-deploy.md` §1.2 のとおり `schema.prisma` を編集（**既存モデルは `User.avatar` の 1 行追加のみ**）
2. `cd apps/api && npx prisma generate && npx prisma db push`（ローカル Docker DB）
3. `db-schema-and-deploy.md` §1.3 のコマンドで SQL を生成し、同節の「期待される出力」を**実出力で置き換える**

### 4.2 T-BE2 エラーコード

- `ErrorCode` に 3 つ追加・`ERROR_CODE_STATUS` に 413 / 415 / 503
- `errorCodeFromStatus`: `PAYLOAD_TOO_LARGE(413)` / `UNSUPPORTED_MEDIA_TYPE(415)` / `SERVICE_UNAVAILABLE(503)` を追加（現状これらは `INTERNAL` に落ちている）
- 既存 `error-codes.spec.ts` / `all-exceptions.filter.spec.ts` に追加ケース

### 4.3 T-BE3 画像処理（`storage-design.md` §4）

公開インターフェース（**この形で固定**。T-BE6 が依存する）:

```ts
export const AVATAR_MAX_BYTES = 5 * 1024 * 1024;
export const AVATAR_SIDE = 512;
export const AVATAR_MAX_INPUT_PIXELS = 4096 * 4096;

@Injectable()
export class AvatarImageProcessor {
  /** JPEG/PNG 以外は UNSUPPORTED_MEDIA_TYPE、デコード不能・ピクセル超過は VALIDATION_ERROR('invalid image') を投げる。 */
  process(input: Buffer): Promise<Buffer>;
}
```

- sharp のグローバル設定（`cache(false)` / `concurrency(1)`）はこのファイルのモジュールスコープで 1 回
- spec は**本物の sharp**で、`sharp({ create: ... })` で生成した画像を入力にする（モックしない）

### 4.4 T-BE4 ストレージ

```ts
export abstract class AvatarStorage {
  /** AVATAR_BUCKET が設定されているか。 */
  abstract isConfigured(): boolean;
  /** contentType / cacheControl は契約 §2-3 の値を実装側で固定する。 */
  abstract put(objectKey: string, jpeg: Buffer): Promise<void>;
  /** 存在しない（404）は成功扱い。 */
  abstract delete(objectKey: string): Promise<void>;
  /** 未設定なら null。 */
  abstract publicUrl(objectKey: string): string | null;
}
```

- `GcsAvatarStorage` は `ConfigService` から `AVATAR_BUCKET` / `AVATAR_PUBLIC_BASE_URL` / `GCS_API_ENDPOINT` を読む（`config.get('X')` の形で書く。`env-coverage.spec.ts` の正規表現が拾う形）
- `GCS_API_ENDPOINT` があれば `new Storage({ apiEndpoint, projectId: 'local' })`、無ければ `new Storage()`（ADC）
- `Storage` クライアントは遅延生成（`AVATAR_BUCKET` 空のときに生成しない）
- spec は `@google-cloud/storage` をモックし、`put` の引数（`contentType`・`cacheControl`・`resumable: false`）・`delete` の 404 握り潰し・`publicUrl` の既定値（E-10）を検証
- `docker-compose.yml` / `.env.example` / `infra/fake-gcs/data/meigicho-avatars-local/.keep` は `storage-design.md` §7

### 4.5 T-BE5 `AvatarService` と `GET /v1/me`

```ts
@Injectable()
export class AvatarService {
  /** P2021（テーブル無し）は null + warn ログ（1 プロセス 1 回で十分）。 */
  findObjectKey(userId: string): Promise<string | null>;
  /** findObjectKey の厳格版。P2021 → SERVICE_UNAVAILABLE。 */
  findObjectKeyOrUnavailable(userId: string): Promise<string | null>;
  /** upsert して直前のキーを返す。P2021 → SERVICE_UNAVAILABLE / P2003 → NOT_FOUND。 */
  replace(userId: string, objectKey: string): Promise<{ previousKey: string | null }>;
  /** 行を消して直前のキーを返す（無ければ null）。P2021 → SERVICE_UNAVAILABLE。 */
  remove(userId: string): Promise<{ previousKey: string | null }>;
  /** GET /v1/me 用。findObjectKey + AvatarStorage.publicUrl。 */
  avatarUrl(userId: string): Promise<string | null>;
}
```

- `replace` / `remove` は `$transaction` 内で `findUnique` → `upsert` / `deleteMany`
- `MeService` のコンストラクタに `AvatarService` を追加。`getMe` で `loadEntitlement` と `avatarUrl` を `Promise.all`。`presentMe` に `avatar_url` を渡す（`MeProfileView` のキー順は `onboarded_at` の次）
- `MeService` の `include: { profile: true }` は**変えない**（新テーブルを include しない — 未反映時に GET /v1/me が落ちるため）

### 4.6 T-BE6 ルート・UseCase

**UploadAvatarUseCase.execute(userId, file?: Express.Multer.File): Promise<MeView>** の手順（契約 §2 の順序を変えない）:

1. `file` が無い → `VALIDATION_ERROR('file is required')`
2. `!storage.isConfigured()` → `SERVICE_UNAVAILABLE`
3. `avatars.findObjectKeyOrUnavailable(userId)`（テーブル存在確認を兼ねる。ここで 503 ならアップロードしない）
4. `processor.process(file.buffer)`
5. `key = 'avatars/' + randomUUID() + '.jpg'`（`node:crypto`）→ `storage.put(key, jpeg)`（失敗 → 例外のまま 500）
6. `avatars.replace(userId, key)` — 失敗したら `storage.delete(key)` をベストエフォートで呼んでから元の例外を再送出
7. `previousKey` があれば `storage.delete(previousKey)` をベストエフォート（失敗は warn）
8. `meService.getMe(userId)` を返す

**DeleteAvatarUseCase.execute(userId): Promise<MeView>**: `avatars.remove(userId)` → `previousKey` があり `storage.isConfigured()` なら `storage.delete` をベストエフォート → `getMe`

**DeleteMeUseCase** 追従: 本人確認の後・`deleteAccount` の**前**に `avatars.findObjectKey(userId)`（寛容版）、`deleteAccount` 成功**後**にベストエフォートで `storage.delete`（Apple 失効と同じ扱い。失敗しても 204）

**Controller**:

```ts
@ThrottleAuthUser()
@Put('avatar')
@UseInterceptors(FileInterceptor('file', AVATAR_UPLOAD_OPTIONS))
uploadAvatar(@CurrentUser() userId: string, @UploadedFile() file?: Express.Multer.File): Promise<MeView>

@ThrottleAuthUser()
@Delete('avatar')
deleteAvatar(@CurrentUser() userId: string): Promise<MeView>
```

- `AVATAR_UPLOAD_OPTIONS` は `storage-design.md` §4.3（`memoryStorage`・`fileSize`・`files: 1`・`fields: 0`・`parts: 1`）
- `@Public()` を付けない。ログに URL・キーを出さない（NFR-AV-7）

### 4.7 T-INFRA1 Terraform

`storage-design.md` §2 の表どおり。`terraform fmt` / `terraform validate` を通す（ローカルに terraform が無ければ PR の `terraform-plan.yml` の結果で確認）。
`allUsers` に付けるロールが **`roles/storage.legacyObjectReader`** であること（`objectViewer` ではない）を必ず確認。

### 4.8 T-CI1 deploy-api.yml

`db-schema-and-deploy.md` §3.1 のとおり。`deploy.needs` を `[test, db-schema]` に変更し、ファイル先頭コメントを更新。

### 4.9 T-IOS1 Networking + Domain

契約 §5 の表のとおり。加えて:

- `ProfileStore`:
  - `public var avatarURL: URL? { profile?.avatarURL }`
  - `public private(set) var isUpdatingAvatar = false`
  - `@discardableResult public func uploadAvatar(jpegData: Data) async -> Bool` / `@discardableResult public func deleteAvatar() async -> Bool` — 既存 `save(_:)` と同じく成功時 `apply(snapshot)`・`errorMessage = nil`、失敗時 `errorMessage = appError.userMessage` で `profile` は変えない
- `Endpoint`: `public let contentType: String`（既定 `"application/json"`）。`init` / `versioned(...)` に引数追加（既定値付きで既存呼び出しはソース互換）。`body != nil` のとき `Content-Type` にこの値
- `MultipartFormData`: `static func singleFile(name: String, filename: String, mimeType: String, data: Data) -> (body: Data, contentType: String)`。境界は `"Boundary-" + UUID().uuidString`、改行は CRLF
- `InMemoryProfileRepository`: アップロードされた JPEG を一時ディレクトリに書き、その `file://` URL を `avatarURL` に入れる（Preview / `useInMemoryStores` 用）
- `DomainTests` の `FakeProfileRepository` にも 2 メソッドを追加

### 4.10 T-IOS2 Core `AvatarImageEncoder`

`storage-design.md` §5.2。公開 API:

```swift
public enum AvatarImageEncoder {
    public enum Error: Swift.Error, Equatable { case unreadableImage, encodingFailed }
    public static let side = 512
    public static func squareJPEG(from data: Data, side: Int = side, quality: Double = 0.85) throws -> Data
}
```

### 4.11 T-IOS3 DesignSystem

`storage-design.md` §6。**既存 3 呼び出し元の見た目を変えない**（`ProfileCard` の 66pt 化はフォントサイズを合わせる）。

### 4.12 T-IOS4 Features

- `AvatarPickerSection`（`Account/` に新規・internal）: `PhotosPicker` + 「写真を選択 / 写真を変更」「写真を削除」の `TourActionButton`。`isUpdatingAvatar` 中は無効化 + `ProgressView`
- 選択 → `loadTransferable(type: Data.self)` → `AvatarImageEncoder.squareJPEG` → 円形プレビューの sheet（「この写真を使う」「キャンセル」）→ `profile.uploadAvatar(jpegData:)`
- 削除 → `confirmationDialog("プロフィール写真を削除しますか？")`（破壊的ボタン「削除」）→ `profile.deleteAvatar()`
- `AccountView`: `ProfileCard(..., avatarURL: profile.avatarURL)` + 直下に `AvatarPickerSection()`
- `HomeView` ツールバー: `profile.avatarURL` があれば `AvatarView(name:, colorHex: theme.seedHex, imageURL:, size: 28)`、無ければ従来の `person.circle`。`accessibilityLabel("アカウント設定")` をボタンに付ける
- 変換失敗は `profile.errorMessage = "画像を読み込めませんでした"`（`ErrorBar` に出る）

---

## 5. T-DOC（docs 更新）

| ファイル | 更新 |
|---|---|
| `docs/01-product-overview.md` | R5-5 に「例外: アカウント本人のアイコンは画像可（本人にのみ表示）。名義は従来どおり画像なし」。`:124` の注記も |
| `docs/02-architecture.md` | GCS（アバター画像）を構成要素に追加。Supabase Storage 不使用は維持 |
| `docs/03-database.md` | `user_avatars` テーブル、スキーマ適用方針（expand → deploy、CI の `db-schema` ジョブ） |
| `docs/04-api.md` | Me 節に `avatar_url`・2 ルート（契約 §6） |
| `docs/05-ios-client.md` | `:1047` 「画像を一切持たない」→ アカウントアイコンの例外と `AsyncImage` 利用 |
| `docs/06-infrastructure.md` | 「画像なし」→ 例外付き。GCS の構成とコスト（`storage-design.md` §8） |
| `docs/08-compliance-risk.md` | 委託先（Google Cloud Storage）・保存データ・退会時削除・App Privacy・Guideline 1.2 の注記 |
| `docs/09-roadmap.md` | Phase 1 系の付帯機能として 1 行追加 |
| `docs/plans/STATUS.md` | §17 の進捗更新 |
| `CLAUDE.md` 既知の未整備 | CI が加算的スキーマ変更を自動適用するようになった旨（T-CI1 実施時） |

---

## 6. 受入基準 → テストケース

### 6.1 BE（Red 先行。`cd apps/api && npm test`）

| AC | テストファイル | ケース |
|---|---|---|
| AC-AV-01 | `me/me.service.spec.ts` | `avatarUrl` が null → `profile.avatar_url: null`（キーが存在すること） |
| AC-AV-02 | `me/avatar/avatar.service.spec.ts` / `me.service.spec.ts` | 行あり → `<base>/<key>`。`MeService` が値をそのまま載せる |
| AC-AV-03 | `me/avatar/avatar.service.spec.ts` | `findUnique` が `P2021` → `findObjectKey` / `avatarUrl` は null |
| AC-AV-04 | `me/use-cases/upload-avatar.use-case.spec.ts`（実 sharp + モック storage/service） | 1000×600 JPEG → `put` に渡された Buffer が 512×512 JPEG、キーが `/^avatars\/[0-9a-f-]{36}\.jpg$/` で userId を含まない |
| AC-AV-04 | `me/avatar/gcs-avatar.storage.spec.ts` | `contentType: 'image/jpeg'`・`cacheControl: 'private, max-age=31536000, immutable'` |
| AC-AV-05 | `me/avatar/avatar-image.processor.spec.ts` | 透過 PNG → JPEG 512×512、透過部が白 |
| AC-AV-06 | `avatar-image.processor.spec.ts` | `withMetadata({ orientation: 6 })` の非正方形 JPEG → 向き適用後に中央クロップ（画素パターンで検証）。出力 `metadata().exif` が undefined |
| AC-AV-07 | `avatar-image.processor.spec.ts` / `me.controller.spec.ts` | HEIC 先頭バイト（`....ftypheic`）・GIF・テキストに `contentType: image/jpeg` を付けて送信 → 415 `UNSUPPORTED_MEDIA_TYPE`、UseCase の storage 未呼び出し |
| AC-AV-08 | `me.controller.spec.ts`（supertest `.attach`） | 5MiB + 1 バイト → 413 `PAYLOAD_TOO_LARGE`、UseCase 未呼び出し。ちょうど 5MiB は 413 にならない |
| AC-AV-09 | `me.controller.spec.ts` | `file` 無し（JSON ボディ）→ 400、`file` 2 つ → 400、テキストフィールド付き → 400、`photo` という名前 → 400 |
| AC-AV-10 | `avatar-image.processor.spec.ts` | 先頭だけ JPEG の壊れたバイト列 → 400 `invalid image`。4097×4097 PNG → 400 |
| AC-AV-11 | `upload-avatar.use-case.spec.ts` | `previousKey` あり → `replace` の**後に** `delete(previousKey)`。`delete` が reject しても MeView を返す |
| AC-AV-12 | `upload-avatar.use-case.spec.ts` | `replace` が reject → `delete(newKey)` が呼ばれ、元の例外が投げられる |
| AC-AV-13 | `upload-avatar.use-case.spec.ts` | `isConfigured() === false` → 503、processor / service / storage 未呼び出し |
| AC-AV-14 | `delete-avatar.use-case.spec.ts` / `me.controller.spec.ts` | 行あり → `remove` → `delete(previousKey)` → 200 `avatar_url: null`。行なし → `delete` 未呼び出しで 200 |
| AC-AV-15 | `me.controller.spec.ts` | 未認証 PUT / DELETE → 401。5 ハンドラすべてに `IS_PUBLIC_KEY` が無い（既存テストを拡張） |
| AC-AV-16 | `me.controller.spec.ts` | 同一ユーザーで PUT 11 回目 → 429。別ユーザー・`GET /v1/me` は影響なし（既存 DELETE /v1/me の形を踏襲） |
| AC-AV-17 | `me/use-cases/delete-me.use-case.spec.ts` | キーあり → `deleteAccount` 後に `storage.delete(key)`。reject でも resolve。`findObjectKey` が null なら未呼び出し |
| AC-AV-18 | `avatar.service.spec.ts` / `upload-avatar.use-case.spec.ts` | `P2021` → `findObjectKeyOrUnavailable` / `replace` / `remove` は 503。UseCase は `put` 前に 503 |
| AC-AV-19 | `config/env-coverage.spec.ts`（既存） | 3 変数追加後も緑 |
| AC-AV-20 | `common/errors/error-codes.spec.ts` / `all-exceptions.filter.spec.ts` | 413/415/503 の写像。`PayloadTooLargeException` → `PAYLOAD_TOO_LARGE` |
| E-3 | `avatar.service.spec.ts` | upsert が `P2003` → `NOT_FOUND` |
| E-10 | `gcs-avatar.storage.spec.ts` | `AVATAR_PUBLIC_BASE_URL` 空 → `https://storage.googleapis.com/<bucket>/<key>`、`AVATAR_BUCKET` 空 → `publicUrl` null・`isConfigured` false |

### 6.2 iOS

| AC | 置き場所 | 内容 |
|---|---|---|
| AC-AV-30 | `NetworkingTests`（`MeDTO` 系） | `avatar_url` が文字列 / `null` / キー欠落の 3 通りでデコード成功、`toDomain()` で `URL?` |
| AC-AV-31 | `NetworkingTests/EndpointTests.swift`・新規 `MultipartFormDataTests.swift` | `contentType` 指定時の `Content-Type`、既定は `application/json`。multipart の body 構造 |
| AC-AV-32 | `CoreTests/AvatarImageEncoderTests.swift` | 横長・縦長・小さい画像 → 512×512 JPEG。不正データ → `.unreadableImage` |
| AC-AV-33 | `DomainTests/ProfileStoreTests.swift` | upload / delete の成功で `profile.avatarURL` 更新、失敗で `errorMessage` が立ち `profile` 不変、`isUpdatingAvatar` が終了後 false |
| AC-AV-34-M〜39-M | 手動（§7.4） | — |

---

## 7. 検証ゲート・確認手順

### 7.1 機械ゲート（`CLAUDE.md`）

```bash
cd apps/api && npx tsc --noEmit
cd apps/api && npm test -- --passWithNoTests
cd apps/api && npm run build
```

iOS（**macOS 環境が必要**。Linux のクラウドエージェントでは実行できないため、その場合は PR に未実施と明記）:

```bash
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
swift test --package-path meigicho/Packages/Core
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/Networking
```

### 7.2 ローカル結合（T-BE6 の完了条件）

```bash
docker build -t meigicho-api-check apps/api && docker run --rm --entrypoint node meigicho-api-check -e "require('sharp'); console.log('sharp ok')"
make up
# 1. register でトークン取得（既存手順）→ TOKEN
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/v1/me | jq .profile.avatar_url                      # null
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -F "file=@sample.heic" localhost:8080/v1/me/avatar | jq .code # UNSUPPORTED_MEDIA_TYPE
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -F "file=@sample.jpg" localhost:8080/v1/me/avatar | jq -r .profile.avatar_url
curl -sI "<上の URL>"                                                                                         # 200 image/jpeg
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" localhost:8080/v1/me/avatar | jq .profile.avatar_url    # null
# 寛容性: user_avatars を消して API を再起動せずに叩く
docker exec meigicho-db psql -U meigicho -c 'DROP TABLE user_avatars;'
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/v1/me | jq .profile.avatar_url                      # null（500 にならない）
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -F "file=@sample.jpg" localhost:8080/v1/me/avatar | jq .code # SERVICE_UNAVAILABLE
# ログイン（POST /v1/auth/login）も 200 のまま
make prisma-push   # 戻す
```

### 7.3 インフラ初回適用（ユーザー作業・マージ後）

1. 初回のみ: `terraform apply -target='google_project_iam_member.terraform_deployer' -target='google_project_iam_member.terraform_planner'`（ローカル・オーナー権限）→ その後 Actions の `Terraform Apply`
2. `terraform output avatars_bucket` を確認
3. `db-schema-and-deploy.md` §2.4 の curl を本番で実行（一覧取得が 401/403 になることを含む）

### 7.4 iOS 手動確認

| ID | 手順 | 期待 |
|---|---|---|
| AC-AV-34-M | アカウント設定 → 写真を選択 → 横長写真 → プレビュー → 使う | カードに円形で反映。アプリ再起動後も表示 |
| AC-AV-35-M | 写真を削除 → 確認 → 削除 | イニシャル表示に戻る |
| AC-AV-36-M | ホームに戻る | 左上の入口がアバター（未設定ならアイコン） |
| AC-AV-37-M | 実機で撮った HEIC 写真を選択 | 成功する |
| AC-AV-38-M | 名義一覧・名義詳細・共有プレビュー | アバターの見た目が変更前と同じ |
| AC-AV-39-M | 機内モードで「この写真を使う」 | エラーバー表示、アバターは変更前のまま |
| 追加 | ログアウト → 別アカウントでログイン | 前のアカウントのアバターが出ない |
| 追加 | VoiceOver でホーム左上 | 「アカウント設定」と読まれる |

---

## 8. ハンドオフ（委譲プロンプト案）

**共通の前置き（全タスク）**: 「まず `/workspace/.claude/skills/implementing-robustly/SKILL.md` を読み従うこと。
契約の正は `docs/plans/backend-domain-modules/api-contract.md` + `docs/plans/avatar-upload/api-contract-delta.md`。
ここに書かれたパス・キー・ステータス・エラーコード・環境変数名を変えないこと。変える必要があれば実装を止めて報告すること。」

### 8.1 BE チェーン（T-BE1〜T-BE6）→ `nest-developer`（model: opus）

> **目的**: アカウント本人のアバター画像 API（`PUT/DELETE /v1/me/avatar`・`GET /v1/me` の `avatar_url`）を実装する。iOS は同じ契約で並列実装中。**本番 DB にスキーマ未反映でも既存機能が落ちない**ことが最重要の非機能要件。
> **対象**: `/workspace/apps/api`、`/workspace/docker-compose.yml`、`/workspace/infra/fake-gcs/`
> **必読**: `docs/plans/avatar-upload/` の `api-contract-delta.md` 全体 / `requirements.md` §1.1・§2・§5 / `storage-design.md` §4・§7 / `db-schema-and-deploy.md` §1 / `plan.md` §4.1〜4.6・§6.1
> **やること**（テスト先行 Red→Green）:
> 1. T-BE1: `plan.md` §4.1。生成した SQL で `db-schema-and-deploy.md` §1.3 を更新
> 2. T-BE2: `plan.md` §4.2
> 3. T-BE3〜T-BE6: `plan.md` §6.1 の AC を失敗する spec に翻訳してから §4.3〜4.6 を実装。§4.3〜4.5 のインターフェースは**その形で**作る
> 4. `plan.md` §7.2 のローカル結合手順を実行
> **従う既存例**: `apps/api/src/mail/mail.sender.ts` + `resend.mail.sender.ts` + `mail.module.ts`（抽象クラスを DI トークンにする形・未設定時の扱い）/ `apps/api/src/me/use-cases/delete-me.use-case.ts:47-60`（ベストエフォート処理とログの出し方）/ `apps/api/src/me/me.controller.spec.ts:20-60`（supertest + req.user 差し込み + throttle テスト）/ `apps/api/src/me/me.service.ts:165-174`（Prisma エラーコードの写し替え）
> **やらないこと**: `app.module.ts`・`auth/**`・`shares/**` の変更。`MeService.deleteAccount` の削除順序配列への追加（**CASCADE に任せる**）。`profiles` / `users` への列追加。`include: { profile: true }` を新テーブルに広げること。新しいエラーコードを契約外に増やすこと。HEIC のサーバー対応
> **注意（`feedback_review_patterns.md`）**: BE-3（UseCase から Prisma を直接叩かない）/ BE-4（対象は常に Bearer の sub）/ BE-6（Prisma エラーを 500 にしない: P2021→503、P2003→404）
> **完了条件**: `cd apps/api && npx tsc --noEmit && npm test && npm run build` 全緑。§7.2 を実測（`docker build` 内の sharp 読み込み、DROP TABLE 後に GET /v1/me とログインが 200 のままであることを含む）
> **報告**: 日本語で ①変更ファイル（file:line）②検証コマンドと結果（テスト件数）③§7.2 の実測ログ ④生成された SQL ⑤残課題

### 8.2 T-INFRA1 + T-CI1 → `nest-developer`（model: sonnet）

> **目的**: アバター画像用 GCS バケットと、本番スキーマを自動適用する CI ジョブを追加する。
> **対象**: `/workspace/infra/terraform/`、`/workspace/.github/workflows/deploy-api.yml`
> **必読**: `docs/plans/avatar-upload/storage-design.md` §2・§3、`db-schema-and-deploy.md` §3、`questions-requirements.md` Q4・Q5
> **やること**: `storage-design.md` §2 の表をそのまま Terraform 化（`storage.tf` 新規・`apis.tf`・`cloud_run.tf`・`outputs.tf`・`terraform_deployer.tf`・`README.md` §2）。`db-schema-and-deploy.md` §3.1 のとおり `db-schema` ジョブを追加
> **従う既存例**: `infra/terraform/secrets.tf:28-35`（リソース単位 IAM の書き方）/ `infra/terraform/cloud_run.tf:37-91`（非機密 env の並べ方）/ `.github/workflows/deploy-api.yml:30-45`（Node ジョブの書き方）
> **やらないこと**: `secrets.tf` の変更（秘密情報は増やさない）。`allUsers` への `roles/storage.objectViewer` 付与（一覧が漏れる）。`--accept-data-loss` の使用。`deploy` ジョブへの `environment:` 追加
> **完了条件**: `terraform fmt -check` と `terraform validate`（使えなければ PR の `terraform-plan.yml` で確認と明記）。workflow は `actionlint` があれば実行
> **報告**: 日本語で ①変更ファイル ②検証結果 ③ユーザーが行う手作業（Secret 登録・初回 apply 手順）④残課題

### 8.3 T-IOS1 → `swift-developer`（model: sonnet）

> **目的**: アバターの取得・アップロード・削除の Networking / Domain 層（UI は別タスク）。
> **対象**: `/workspace/meigicho/Packages/Networking`、`/workspace/meigicho/Packages/Domain`
> **必読**: `docs/plans/avatar-upload/api-contract-delta.md` §1〜3・§5 / `plan.md` §4.9・§6.2
> **やること**: §5 の表と §4.9 のとおり。AC-AV-30・31・33 を先にテスト化
> **従う既存例**: `Packages/Networking/Sources/Networking/Remote/RemoteProfileRepository.swift:16-24` / `Packages/Domain/Sources/Domain/ProfileStore.swift:124-137`（`save` の成功・失敗の扱い）/ `Packages/Networking/Sources/Networking/DTO/MeDTO.swift:32-56`（`CodingKeys`）
> **やらないこと**: `Features/**`・`App/**`・`ApiClient.swift` のリトライ/refresh ロジックの変更。DataStore（SwiftData）への保存
> **注意**: IOS-2（キーは `CodingKeys` に文字列で）/ IOS-5（Domain から Networking を参照しない）/ IOS-12（`Networking` を `Network` に戻さない）
> **完了条件**: `swift test --package-path meigicho/Packages/{Domain,Networking}` 全緑 + xcodebuild BUILD SUCCEEDED
> **報告**: 日本語で ①変更ファイル（file:line）②テスト結果 ③残課題

### 8.4 T-IOS2 + T-IOS3 → `swift-developer`（model: sonnet）

> **目的**: 端末側の画像変換（Core）と `AvatarView` / `ProfileCard` の画像対応（DesignSystem）。
> **対象**: `/workspace/meigicho/Packages/Core`、`/workspace/meigicho/Packages/DesignSystem`
> **必読**: `storage-design.md` §5・§6 / `plan.md` §4.10・§4.11
> **やること**: `AvatarImageEncoder`（AC-AV-32 を先にテスト化）。`AvatarView(name:colorHex:imageURL:size:)`、`ProfileCard(avatarURL:)`
> **従う既存例**: `DesignSystem/Components/AvatarView.swift`・`FormComponents.swift:304-336`
> **やらないこと**: 既存 3 呼び出し元（`ListRow.swift:118`・`SharePreviewView.swift:53`・`IdentityDetailView`）の変更。UIKit への依存を Core に入れること
> **完了条件**: `swift test --package-path meigicho/Packages/Core` 全緑 + xcodebuild BUILD SUCCEEDED
> **報告**: 日本語で ①変更ファイル ②テスト結果 ③既存呼び出し元の見た目に影響が無い根拠 ④残課題

### 8.5 T-IOS4 → `swift-developer`（model: sonnet）

> **目的**: アカウント設定画面でのアバター設定・削除 UI と、ホームの入口表示。
> **対象**: `/workspace/meigicho/Packages/Features/Sources/Features/{Account,Home}`
> **必読**: `requirements.md` §1.2 / `plan.md` §4.12・§7.4 / `api-contract-delta.md` §5 の文言表
> **従う既存例**: `AccountView.swift:84-90`（`ProfileCard`）・`:250-280`（カード UI）・`:56-61`（sheet）/ `HomeView.swift:47-52`（ツールバー）
> **やらないこと**: Domain / Networking / Core / DesignSystem の変更（必要なら止めて報告）。`Info.plist` への写真権限追加（PhotosPicker は不要）。対話的クロップ
> **注意**: IOS-1・IOS-3（導線から送信・表示まで縦串で通す）
> **完了条件**: xcodebuild BUILD SUCCEEDED。§7.4 の手動確認を実施して結果を報告（BE 稼働が前提のものは結合時）
> **報告**: 日本語で ①変更ファイル ②ビルド結果 ③手動確認の結果 ④残課題

### 8.6 R → `code-reviewer`（**別セッション** / model: opus）

> **差分範囲**: `main...HEAD` のうち `apps/api/**`・`docker-compose.yml`・`infra/**`・`.github/workflows/deploy-api.yml`・`meigicho/Packages/**`
> **観点**: rule 04 の 7 点 + **NFR-AV-1（`user_avatars` 不在時に既存機能が落ちない — `include` の広がり・`deleteAccount` への混入が無いか）** + NFR-AV-3（公開範囲: `legacyObjectReader`・キーに userId を含まない・`Cache-Control: private`）+ NFR-AV-7（ログ）+ 補償削除の順序 + 契約 3 層（Prisma / dto / iOS DTO）の一致 + CI の `--accept-data-loss` 不使用
> **スコープ外（指摘不要）**: サーバー HEIC 対応・対話的クロップ・共有相手への表示・`prisma migrate` 移行・孤立オブジェクト掃除
> **保存先**: `docs/plans/avatar-upload/review.md`

---

## 9. 実装前チェックリスト

- [ ] Q0（R5-5 の例外化・ロードマップ追加）の回答
- [ ] Q3（別テーブル `user_avatars`）の回答 — 変わる場合は契約は不変、`db-schema-and-deploy.md` と T-BE1/T-BE5 を planner が更新
- [ ] Q5（CI に `db push`）の回答 — B なら T-CI1 を外し、PR に手動適用手順（`db-schema-and-deploy.md` §2.3）を記載
- [ ] Q1・Q2・Q4・Q6〜Q8 は推奨案で進行
- [ ] ユーザー作業: `PROD_DATABASE_DIRECT_URL` 登録 / 初回 Terraform apply / App Privacy 更新 / `.env.example` 追記（エージェントが書けなかった場合）
