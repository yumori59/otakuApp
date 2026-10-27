# storage-design — avatar-upload

ストレージ選定・GCS の構成（Terraform）・画像処理（サーバー / 端末）・ローカル開発・`AvatarView` の拡張方針。
判断の経緯は `questions-requirements.md` Q1 / Q2 / Q4 / Q8、契約は `api-contract-delta.md`。

---

## 1. ストレージの選定: GCS

| 観点 | GCS（採用） | Supabase Storage（却下） |
|---|---|---|
| 既存方針 | GCP（Cloud Run / Artifact Registry / Secret Manager）に同居。`docs/06` の構成に自然に加わる | `docs/02:7,155`・`docs/06:9,46`・`docs/08:28` が**不使用と明記** |
| 認証 | Cloud Run 実行 SA（`meigicho-api`）の **ADC。鍵ゼロ** | `service_role` キー（RLS を素通りする全権限キー）を Secret Manager に追加して API に渡す |
| IaC | `google_storage_bucket` + バケット IAM を `infra/terraform/` に追加 | Terraform 管理外（`infra/terraform/README.md` の対象外節） |
| SDK | `@google-cloud/storage`（ADC を自動解決） | `@supabase/supabase-js` を API に追加（DB は Prisma なので Storage のためだけに入る） |
| リージョン | `asia-northeast1` | ap-northeast-1 |

**結論**: GCS が「秘密情報を増やさない」「IaC に乗る」「方針を崩さない」の全てを満たす最もシンプルで安全な選択肢。

---

## 2. バケット構成（Terraform: `infra/terraform/storage.tf` 新規）

| 設定 | 値 | 理由 |
|---|---|---|
| 名前 | `${var.project_id}-avatars` | グローバル一意。tfstate バケット（`<project_id>-tfstate`）と同じ命名規則 |
| `location` | `var.region`（`asia-northeast1`） | `docs/08` 越境回避 |
| `storage_class` | `STANDARD` | 小さいファイル・読み取り中心 |
| `uniform_bucket_level_access` | `true` | ACL を使わず IAM のみで制御（オブジェクト単位の公開設定ミスを防ぐ） |
| `public_access_prevention` | `"inherited"` | `allUsers` 付与のため。`enforced` にしない |
| `versioning` | 無効 | 削除したアバターを残さない |
| `soft_delete_policy.retention_duration_seconds` | `0` | 既定 7 日の soft delete を無効化。**削除・退会後に画像を保持しない**（`docs/08` の保存期間最小化） |
| `force_destroy` | `false` | `terraform destroy` の事故防止 |
| CORS | 設定しない | 取得はネイティブアプリのみ（ブラウザ経由の取得なし） |
| `labels` | `app = "meigicho"`, `purpose = "avatars"` | 任意 |

### 2.1 IAM（バケット単位。プロジェクト全体には付けない）

| メンバー | ロール | 含む権限 | 理由 |
|---|---|---|---|
| `serviceAccount:meigicho-api@...`（実行 SA） | `roles/storage.objectUser` | objects.create / get / delete / update / list | アップロード・置換・削除。バケット設定や IAM は変更できない |
| `allUsers` | **`roles/storage.legacyObjectReader`** | **objects.get のみ** | 公開 URL での取得。**`roles/storage.objectViewer` は `objects.list` を含み、全オブジェクトを列挙できてしまうので使わない** |

### 2.2 Terraform を実行する SA への追加

| SA | 追加ロール | 理由 |
|---|---|---|
| `terraform-deployer` | `roles/storage.admin` | バケット作成・バケット IAM の変更 |
| `terraform-planner` | `roles/storage.bucketViewer` | `terraform plan` でバケットのメタデータを読む（IAM ポリシーの読み取りは既存 `roles/iam.securityReviewer` に含まれる） |

> **鶏と卵に注意**: `terraform-deployer` が自分に `roles/storage.admin` を付ける apply と、バケットを作る apply が同時だと IAM 伝播待ちで初回失敗し得る。
> 初回は (1) `-target='google_project_iam_member.terraform_deployer'` → (2) 全体 apply の 2 段階で行うか、オーナー権限のローカル apply で行う（`plan.md` §7.3）。

### 2.3 その他の Terraform 変更

| ファイル | 変更 |
|---|---|
| `apis.tf` | `storage.googleapis.com` を `required_apis` に追加 |
| `cloud_run.tf` | 非機密 env に `AVATAR_BUCKET = google_storage_bucket.avatars.name`、`AVATAR_PUBLIC_BASE_URL = "https://storage.googleapis.com/${google_storage_bucket.avatars.name}"` を追加。`depends_on` に実行 SA のバケット IAM を追加 |
| `outputs.tf` | `avatars_bucket` を出力 |
| `secrets.tf` | **変更なし**（秘密情報は増えない） |
| `README.md` | §2 権限表に実行 SA のバケット権限を追記。§0 は変更不要 |

`GCS_API_ENDPOINT` は Cloud Run に**設定しない**（空 = 本物の GCS）。

---

## 3. 配信方式

- 公開 URL: `https://storage.googleapis.com/<bucket>/avatars/<UUID v4>.jpg`
- キーは**アップロードごとに新規の 128bit 乱数**。userId を含めない（URL から本人を特定させない・他人のキーを推測させない）
- オブジェクトのメタデータ: `contentType: image/jpeg`、`cacheControl: private, max-age=31536000, immutable`
  - `private`: Google のエッジキャッシュに載せない → **削除後すぐに取得不能**
  - `immutable` + 長い `max-age`: キーが変わる設計なので端末キャッシュは安全に長期化できる
- 署名付き URL・API プロキシを採らない理由は `questions-requirements.md` Q4

### 3.1 組織ポリシーで公開できない場合のフォールバック

GCP 組織に属し `constraints/storage.publicAccessPrevention` や `constraints/iam.allowedPolicyMemberDomains` が強制されていると `allUsers` を付与できない（`terraform apply` が 412 / 400 で失敗する）。
その場合は**契約を変えずに**サーバー実装だけ切り替える:

- `avatar_url` を V4 署名付き URL（有効期限 7 日）で返す。実行 SA に自分自身への `roles/iam.serviceAccountTokenCreator` を付与（signBlob 用）
- iOS は URL をキャッシュキーにしているので、URL が変わるたびに再取得になる（許容）

現状の Terraform（`project_id` の手動作成・個人プロジェクト想定。`docs/12-app-store-release.md` §6.2）では組織ポリシーは無い前提。

---

## 4. サーバーの画像処理（`sharp`）

### 4.1 ライブラリ

| 選択肢 | 判定 |
|---|---|
| **`sharp`（libvips）**（採用） | 高速・低メモリ・Node 22 / `node:22-alpine`（musl）/ Ubuntu（CI）向けのビルド済みバイナリを npm が配布。HEIC は非対応（Q1 で端末変換に寄せた） |
| `jimp` | 純 JS で依存は軽いが、5MiB の PNG デコードで数百 MB を使い CPU も遅い。Cloud Run 512Mi に不向き |
| 処理しない（検証のみ） | EXIF 残存・ファイルの無害化ができない（Q1-C 却下） |

### 4.2 パイプライン（`AvatarImageProcessor.process(buffer): Promise<Buffer>`）

```text
入力 Buffer（≤ 5MiB）
  ├─ マジックバイト判定: JPEG(FF D8 FF) / PNG(89 50 4E 47 0D 0A 1A 0A) 以外 → UNSUPPORTED_MEDIA_TYPE
  ├─ sharp(buffer, { limitInputPixels: 4096*4096, failOn: 'error', pages: 1 })
  │     デコード失敗 / ピクセル超過 → VALIDATION_ERROR('invalid image')
  ├─ .rotate()                       … EXIF Orientation を適用（以後 EXIF は捨てる）
  ├─ .flatten({ background: '#ffffff' })  … 透過 PNG を白で合成
  ├─ .resize(512, 512, { fit: 'cover', position: 'centre' })  … 短辺基準の中央クロップ + 縮小/拡大
  └─ .jpeg({ quality: 85, mozjpeg: true })  … withMetadata() を呼ばない = EXIF/GPS/XMP を出力しない
出力 Buffer（512×512 JPEG、通常 30〜80KB）
```

- モジュール初期化時に `sharp.cache(false)` と `sharp.concurrency(1)` を設定（Cloud Run 512Mi・concurrency 80 で同時アップロードが重なっても libvips のスレッド数とキャッシュでメモリを膨らませない）
- `limitInputPixels` 4096²: RGBA 展開で最悪 64MB。正規クライアントは 512px を送るので実際は数 MB
- マジックバイトは sharp に渡す**前**に判定する（sharp は GIF / WebP / TIFF / SVG も読めるため、受理形式を絞るのは自前の判定で行う。SVG を libvips に渡さないことも目的）

### 4.3 アップロード受け口（multer）

`@nestjs/platform-express` 同梱の `FileInterceptor('file', options)` を使う（新規依存は型定義 `@types/multer` のみ）。

```ts
{
  storage: memoryStorage(),            // ディスクに書かない（Cloud Run の /tmp はメモリ消費）
  limits: {
    fileSize: 5 * 1024 * 1024,          // 超過 → Nest が PayloadTooLargeException(413)
    files: 1,                           // 超過 → BadRequestException(400)
    fields: 0,                          // テキストフィールド禁止 → 400
    parts: 1,
  },
}
```

- 非 multipart のリクエストは multer が素通しし `file` が `undefined` → UseCase で `VALIDATION_ERROR('file is required')`
- 413 は `errorCodeFromStatus` の追加写像で `PAYLOAD_TOO_LARGE` になる（`api-contract-delta.md` §0.2）

### 4.4 Docker / CI への影響

- `sharp` は optionalDependencies（`@img/sharp-linuxmusl-x64` / `@img/sharp-linux-x64` 等）でプラットフォーム別バイナリを入れる。`package-lock.json` に**両プラットフォーム分のエントリが載っていること**を確認する（macOS で lock を生成すると Linux 用が欠けることがある npm の既知問題）
- 検証: `docker build apps/api` が通り、コンテナ内で `node -e "require('sharp')"` が成功すること（`plan.md` §7.2）
- イメージサイズは +約 10〜20MB

---

## 5. 端末の画像処理（iOS）

### 5.1 置き場所

`meigicho/Packages/Core/Sources/Core/AvatarImageEncoder.swift`（新規）。ImageIO / CoreGraphics / UniformTypeIdentifiers のみに依存し、UIKit を使わない（`CoreTests` で単体テスト可能にするため）。

### 5.2 手順

```text
PhotosPicker の PhotosPickerItem
  └─ loadTransferable(type: Data.self)        … HEIC / JPEG / PNG 等の元データ
       └─ CGImageSourceCreateWithData
            └─ CGImageSourceCreateThumbnailAtIndex(
                 kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,   … EXIF 向きを適用
                 kCGImageSourceThumbnailMaxPixelSize: 2048)         … 48MP の写真でも全展開しない
                 └─ 短辺で中央正方形に cropping(to:)
                      └─ 512×512 の CGContext（sRGB, premultipliedLast, 白で塗ってから描画）
                           └─ CGImageDestination で JPEG（kCGImageDestinationLossyCompressionQuality: 0.85、メタデータ辞書を渡さない）
```

- 出力は必ず 5MiB を大きく下回る（512² JPEG）。サーバーの上限に当たるのは改造クライアントのみ
- 失敗（デコード不能）は `AvatarImageEncoder.Error.unreadableImage` → View で「画像を読み込めませんでした」

### 5.3 PhotosPicker

- `PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared())`
- プロセス外ピッカーなので**写真ライブラリの権限ダイアログは出ず、`Info.plist` への `NSPhotoLibraryUsageDescription` 追加は不要**
- 選択後 `.task(id: pickerItem)` で読み込み → 変換 → プレビュー sheet

---

## 6. `AvatarView` の拡張方針（DesignSystem）

### 6.1 現状

```swift
public init(name: String, colorHex: String)   // 44pt 固定・イニシャル + 色
```

呼び出し元: `FormComponents.swift:321`（`ProfileCard`、`.scaleEffect(1.5)` で 66pt 相当に拡大）、`ListRow.swift:118`、`SharePreviewView.swift:53`。

### 6.2 拡張（**既存の呼び出しはソース互換・見た目不変**）

```swift
public init(name: String, colorHex: String, imageURL: URL? = nil, size: CGFloat = 44)
```

| 状態 | 表示 |
|---|---|
| `imageURL == nil` | 従来どおりイニシャル + 色 |
| 読み込み中 / 失敗 | イニシャル + 色（プレースホルダー。空枠やスピナーを出さない — `docs/07` のレイアウト方針と同じ） |
| 成功 | `AsyncImage` の画像を `.resizable().scaledToFill()` で円形クリップ |

- イニシャルのフォント: `size == 44` のときは従来の `DSFont.bodyBold`。それ以外は `size * 0.38` の太字（`ProfileCard` で 66pt にしたとき、従来の `scaleEffect(1.5)` の見た目と一致させる）
- `.accessibilityHidden(true)` は維持（装飾扱い。`docs/05:680`）
- `ProfileCard` は `.scaleEffect(1.5)` をやめて `AvatarView(..., size: 66)` にする（画像がぼやけないように）。`ProfileCard` に `avatarURL: URL? = nil` を追加し `AvatarView` に渡す。**`IdentityDetailView` の呼び出しは変更しない**（既定値 `nil`）

### 6.3 編集 UI は `ProfileCard` に入れない

`ProfileCard` は名義詳細でも使う汎用カードなので、写真選択・削除の操作は `AccountView` 側（`ProfileCard` の直下）に置く。
DesignSystem には新コンポーネントを足さず、既存の `TourActionButton`（「写真を選択」「写真を削除」— 後者は `isDestructive: true`）を使う。

---

## 7. ローカル開発（fake-gcs-server）

`docker-compose.yml` に追加:

```yaml
  gcs:
    image: fsouza/fake-gcs-server:1
    container_name: meigicho-gcs
    command: ["-scheme", "http", "-port", "4443", "-public-host", "localhost:4443", "-backend", "memory"]
    ports:
      - "4443:4443"
    volumes:
      - ./infra/fake-gcs/data:/data:ro   # infra/fake-gcs/data/meigicho-avatars-local/.keep でバケットを事前作成
```

`api.environment` に追加（`env-coverage.spec.ts` が src の読む変数と突き合わせる）:

```yaml
      AVATAR_BUCKET: meigicho-avatars-local
      AVATAR_PUBLIC_BASE_URL: http://localhost:4443/meigicho-avatars-local
      GCS_API_ENDPOINT: http://gcs:4443
```

- API コンテナからは `http://gcs:4443`、シミュレータからは `http://localhost:4443` で同じオブジェクトに届く
- `@google-cloud/storage` は `apiEndpoint` を指定すると既定で認証を行わない（`useAuthWithCustomEndpoint` 既定 `false`）。**実装時に v7 系で挙動を確認すること**
- fake-gcs-server は IAM を持たないので公開・非公開の区別は検証できない（本番の IAM は Terraform と手動確認で担保）
- iOS シミュレータの ATS: 既存のローカル API（`http://localhost:8080`）と同じ例外で `localhost:4443` も読める想定。読めなければ `project.yml` の ATS 例外を確認
- 詰まった場合は `AVATAR_BUCKET` を空にして「機能無効（503）」で開発を進めてよい（Q8）

`apps/api/.env.example`（ホストで `make api-dev` するとき）にも同じ 3 変数を追記する（`GCS_API_ENDPOINT=http://localhost:4443`）。ハーネスの deny で書けなければ PR に手動追記項目として記載。

---

## 8. コスト・コンプライアンス

- 容量: 1 枚 ≈ 30〜80KB。1 万ユーザー全員が設定しても < 1GB → 月数円。操作課金（Class A/B）も無視できる規模
- 帯域: 端末キャッシュ（`max-age` 1 年・キー不変）により再取得は URL 変更時のみ
- `docs/06-infrastructure.md`: 「画像なし」の記述をアカウントアイコンの例外付きに更新し、上記コストを追記
- `docs/08-compliance-risk.md`: 委託先一覧の Google Cloud に「Cloud Storage（アカウントアイコン画像）」を追記。保存データに「本人がアップロードした画像（任意）」を追記。退会時に削除されること
- App Store Connect の App Privacy: 「写真またはビデオ」を「ユーザーに関連付けられる / App の機能」で申告（**ユーザー作業**。審査提出前に必要）
- Guideline 1.2（UGC）: 本人にしか表示しないため対象外。**共有相手に表示する変更を入れる場合は通報・ブロック等が必要になる**ことを `docs/08` に注記
