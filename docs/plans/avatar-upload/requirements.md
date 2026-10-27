# requirements — avatar-upload

サインイン済みユーザーが、自分のアカウントのプロフィールアイコン（アバター画像）を設定・削除できるようにする。

- 起票: 2026-10-27 / aidlc-planner
- 前提となる決定: `questions-requirements.md` の Q0〜Q8（**[推奨] を暫定採用**。Q0 / Q3 / Q5 は要ユーザー確認）
- 関連: `api-contract-delta.md`（契約の正）/ `storage-design.md`（GCS・画像処理）/ `db-schema-and-deploy.md`（DB 変更・本番手順・CI）/ `plan.md`（タスク分解）

---

## 0. スコープ

### 対象

- iOS: アカウント設定画面（`AccountView`）でのアバター表示・写真選択・正方形クロップ・アップロード・削除。ホーム左上のアカウント入口にも表示
- BE: `PUT /v1/me/avatar`・`DELETE /v1/me/avatar` の新設、`GET /v1/me`（および `PATCH /v1/me` の応答）に `profile.avatar_url` を追加
- DB: `user_avatars` テーブル新設
- インフラ: GCS バケット・IAM・Cloud Run 環境変数（Terraform）、`deploy-api.yml` への `db-schema` ジョブ追加、ローカル用 `fake-gcs-server`
- docs: R5-5 の例外追記ほか（`plan.md` T-DOC）

### スコープ外（明示）

| 項目 | 理由 |
|---|---|
| 名義（identity）のアバター画像 | R5-5 は名義について維持（Q0） |
| 共有相手（受信箱・SharedBoard・共有プレビュー）への本人アバター表示 | 表示すると UGC になり Guideline 1.2 対応が必要（Q0）。別計画 |
| 対話的クロップ UI | Q6。中央自動クロップのみ |
| サーバー側 HEIC デコード | Q1。HEIC→JPEG は端末で行う |
| `prisma migrate` への移行（マイグレーション履歴の導入） | Q5-C。別計画で起票を推奨 |
| 孤立オブジェクトの定期掃除ジョブ | E-7。発生条件が限定的なため記録のみ |
| 画像の不適切コンテンツ判定（Vision API 等） | 本人にしか表示しないため不要（Q0） |

---

## 1. 機能要件

### 1.1 BE

| ID | 要件 |
|---|---|
| FR-AV-1 | `GET /v1/me` の `profile` に `avatar_url: string \| null` を追加する。アバター未設定なら `null`。設定済みなら公開取得可能な絶対 URL（`https://...`） |
| FR-AV-2 | `PUT /v1/me/avatar`（`multipart/form-data`、フィールド名 `file`）で本人のアバターを設定・置換する。成功時 `200` で `GET /v1/me` と同形の `MeView` を返す |
| FR-AV-3 | 受理する形式は **JPEG / PNG のみ**。判定は**ファイル先頭のマジックバイト**で行い、`Content-Type` ヘッダやファイル名を信用しない。HEIC・GIF・WebP・その他は `415 UNSUPPORTED_MEDIA_TYPE` |
| FR-AV-4 | アップロード上限は **5 MiB（5,242,880 バイト）**。超過は `413 PAYLOAD_TOO_LARGE` |
| FR-AV-5 | サーバーは受理した画像を必ず**再エンコード**する: EXIF の向きを適用 → 短辺に合わせて中央で正方形クロップ → **512×512** にリサイズ → **JPEG（品質 85）**。色空間は sRGB に変換し、EXIF・GPS・XMP・ICC 等のメタデータは出力に含めない |
| FR-AV-6 | デコードできない画像・入力ピクセル数が上限（16,777,216 px = 4096²）を超える画像は `400 VALIDATION_ERROR` |
| FR-AV-7 | 置換時は、新しいオブジェクトを保存 → DB の参照を切り替え → **旧オブジェクトを削除**（失敗してもリクエストは成功させ、警告ログのみ） |
| FR-AV-8 | `DELETE /v1/me/avatar` で本人のアバターを削除する。DB の参照を消し、オブジェクトを削除する。**未設定でも `200`（冪等）**。応答は `MeView`（`avatar_url: null`） |
| FR-AV-9 | 両ルートとも**認証必須**（`@Public()` を付けない）。対象は常に Bearer の本人。パス・クエリ・ボディで他ユーザーを指定する経路を作らない |
| FR-AV-10 | アカウント削除（`DELETE /v1/me`）時、アバターのオブジェクトも削除する（ベストエフォート。失敗しても 204 を変えない）。DB 行は `users` の `ON DELETE CASCADE` で消える |
| FR-AV-11 | ストレージ未設定（`AVATAR_BUCKET` が空）のとき、`PUT` は `503 SERVICE_UNAVAILABLE`。`GET /v1/me` は従来どおり動作する |
| FR-AV-12 | `user_avatars` テーブルが DB に**存在しない**（本番未反映）とき: `GET /v1/me` / `PATCH /v1/me` は `avatar_url: null` で正常応答、`PUT` / `DELETE /v1/me/avatar` は `503 SERVICE_UNAVAILABLE`、アカウント削除は従来どおり成功する |
| FR-AV-13 | `PUT` / `DELETE /v1/me/avatar` に userId 単位のレート制限（10 回 / 5 分）をかける |

### 1.2 iOS

| ID | 要件 |
|---|---|
| FR-AV-20 | アカウント設定画面の `ProfileCard` に現在のアバターを表示する。未設定・読み込み中・読み込み失敗時は既存のイニシャル＋テーマ色（プレースホルダー）を表示する |
| FR-AV-21 | `ProfileCard` の直下に「写真を選択」（未設定時）/「写真を変更」「写真を削除」（設定時）の操作を置く。写真選択は SwiftUI 標準の `PhotosPicker`（画像のみ） |
| FR-AV-22 | 選択した画像を端末で**中央正方形クロップ → 512×512 → JPEG（品質 0.85）**に変換する。HEIC を含む ImageIO が読める形式はすべてここで JPEG になる。向き（EXIF Orientation）を適用し、メタデータは書き出さない |
| FR-AV-23 | 変換後に円形プレビューを出し、「この写真を使う」で `PUT /v1/me/avatar` を送る。送信中は操作ボタンを無効化しプログレスを出す |
| FR-AV-24 | 「写真を削除」は確認ダイアログ（`confirmationDialog`、破壊的ボタン）を経て `DELETE /v1/me/avatar` を送る |
| FR-AV-25 | 成功時はサーバー応答の `MeView` で `ProfileStore` を丸ごと差し替える（既存 `save` と同じく「サーバーが正」） |
| FR-AV-26 | 失敗時は既存の `ErrorBar` にメッセージを出し、表示中のアバターは変更前のまま |
| FR-AV-27 | ホーム左上のアカウント入口（`HomeView` ツールバー）に、アバター設定済みなら 28pt の円形アバターを出す。未設定なら現状の `person.circle` のまま |
| FR-AV-28 | 既存の `AvatarView` の呼び出し元（名義の一覧・詳細・共有プレビュー・フォーム）の見た目を変えない |

---

## 2. 非機能要件

| ID | 要件 |
|---|---|
| NFR-AV-1 **寛容性** | 本番 DB にスキーマ未反映でも、既存機能（サインイン・登録・GET/PATCH /v1/me・受信箱・アカウント削除）は一切影響を受けない（Q3-C で構造的に担保。FR-AV-12） |
| NFR-AV-2 **秘密情報ゼロ** | ストレージの認証は Cloud Run 実行 SA の ADC のみ。サービスアカウントキー・API キーを新設しない。新しい環境変数はすべて非機密 |
| NFR-AV-3 **プライバシー** | 公開 URL は推測不能（128bit 乱数、userId を含まない）。バケットの一覧取得は不可。保存画像に位置情報等のメタデータを残さない。削除後は即時に取得不能（`Cache-Control: private`） |
| NFR-AV-4 **リソース** | Cloud Run 512Mi で安全に動く: 入力ピクセル上限 4096²・sharp のキャッシュ無効・並列度 1。アップロード上限 5MiB は multer のメモリストレージで扱える |
| NFR-AV-5 **リージョン** | バケットは `asia-northeast1`（`docs/08` 越境移転回避） |
| NFR-AV-6 **コスト** | 1 枚 ≈ 30〜80KB。1 万ユーザーで < 1GB（月額数円規模）。帯域は端末キャッシュで抑える |
| NFR-AV-7 **ログ** | 画像データ・URL・オブジェクトキーをエラーメッセージに載せない。ログは `user_id` と操作種別のみ |
| NFR-AV-8 **後方互換** | `avatar_url` の追加は加算のみ。旧 iOS は未知キーを無視する（`Decodable` の既定動作）。新 iOS は `avatar_url` 欠落でも `nil` として扱う |

---

## 3. 制約

- BE レイヤ: Controller → UseCase → Service → Prisma（ADR-009）。Controller / UseCase から Prisma を直接触らない
- iOS 依存: View → Store → Repository。Features から Networking を直接参照しない
- エラーコードは契約（`api-contract-delta.md` §0）に無いものを増やさない
- `apps/api/src/config/env-coverage.spec.ts`: src が読む環境変数は `docker-compose.yml` の `api.environment` に必ず載せる。逆に src が読まない変数を compose に置かない
- `.env.example` はハーネスの deny 設定でエージェントが書けない可能性がある（CLAUDE.md 既知事項）。書けなければ手動追記項目として PR に明記する
- PhotosPicker はプロセス外で動くため**写真ライブラリの権限要求（`NSPhotoLibraryUsageDescription`）は不要**。追加しない

---

## 4. 決定事項（Q の暫定回答の要約）

| ID | 決定 | 却下案 |
|---|---|---|
| D1 | ストレージは **GCS**（`asia-northeast1`、Terraform 管理、ADC） | Supabase Storage（方針撤回 + `service_role` キーが必要） |
| D2 | DB は**別テーブル `user_avatars`**（`object_key` を保存、URL は API で組み立て） | `profiles.avatar_url` / `users.avatar_url` 列（未反映時に全サインインが 500） |
| D3 | 配信は**公開読み取り（get のみ）+ 乱数キー + `Cache-Control: private`** | 署名付き URL（IAM 権限追加・キャッシュ不可）/ API プロキシ（帯域コスト） |
| D4 | HEIC→JPEG は**端末**。サーバーは JPEG/PNG を受けて**必ず再エンコード** | サーバー HEIC 対応（libheif 自前ビルド）/ 再エンコード無し（EXIF 残存） |
| D5 | アップロードは **`PUT /v1/me/avatar` + multipart/form-data（`file`）** | 生バイナリ body（Nest のグローバル body parser に raw を足す必要があり影響が広い）/ Base64 JSON（33% 膨張・JSON body 上限 100KB の変更が必要） |
| D6 | 応答は **`MeView`（200）**。DELETE も 200 + `MeView` | DELETE 204（iOS が再取得の往復をしなければならない） |
| D7 | `deploy-api.yml` に **`db-schema` ジョブ**（diff 表示 → `db push`、`--accept-data-loss` なし、fail-closed） | 手動のみ / migrate 移行（別計画） |
| D8 | ローカルは **`fake-gcs-server`** | 未設定 503 のみ |

---

## 5. エッジケース

| ID | ケース | 期待動作 |
|---|---|---|
| E-1 | アバター未設定で `DELETE /v1/me/avatar` | 200、`avatar_url: null`。ストレージは呼ばない |
| E-2 | 同一ユーザーがほぼ同時に 2 回 `PUT` | どちらか後勝ち。DB は常に 1 行。先勝ち側の新オブジェクトが孤立し得る（E-7） |
| E-3 | `PUT` 中にアカウント削除 | DB の upsert が FK 違反（`P2003`）または対象無しで失敗 → 新オブジェクトを補償削除し 404 `NOT_FOUND` |
| E-4 | GCS への保存が失敗 | 500 `INTERNAL`。DB は変更しない（旧アバターがそのまま残る） |
| E-5 | GCS 保存成功・DB 更新失敗 | 新オブジェクトを補償削除（ベストエフォート）して 500 |
| E-6 | 旧オブジェクト削除が失敗 / 既に存在しない（404） | 成功扱い。警告ログ（404 はログ不要） |
| E-7 | 孤立オブジェクト | E-2 / E-5 補償失敗 / E-6 で発生し得る。乱数キーで本人にも参照されないため実害は容量のみ。掃除ジョブはスコープ外 |
| E-8 | `user_avatars` テーブル未作成（本番未反映） | FR-AV-12 |
| E-9 | `AVATAR_BUCKET` 未設定 | FR-AV-11。DELETE は DB 行があれば行を消し（ストレージ削除はスキップして警告）、無ければ 200 |
| E-10 | `AVATAR_PUBLIC_BASE_URL` 未設定 | `https://storage.googleapis.com/<AVATAR_BUCKET>` を既定とする。`AVATAR_BUCKET` も空なら `avatar_url` は `null` |
| E-11 | 極端な縦横比（パノラマ等） | 短辺基準の中央クロップ。短辺 < 512 なら拡大して 512×512 |
| E-12 | 透過 PNG | 白背景で合成して JPEG 化（黒潰れ防止） |
| E-13 | アニメーション PNG（APNG）/ マルチフレーム | 先頭フレームのみ使用 |
| E-14 | `file` 以外のフィールド・複数ファイル | 400 `VALIDATION_ERROR`（multer の `files: 1`・未知フィールド拒否） |
| E-15 | オフライン / タイムアウト（iOS） | 既存の `AppError.offline` 等で `ErrorBar`。アバター表示は変更前のまま |
| E-16 | 画像 URL の読み込み失敗（iOS） | イニシャルのプレースホルダーを表示（空枠を出さない） |
| E-17 | ログアウト → 別アカウントでログイン | `ProfileStore.clear()` で `avatarURL` も消える（既存のクリア経路に乗る） |
| E-18 | 旧 iOS（`avatar_url` を知らない） | 影響なし（NFR-AV-8） |

---

## 6. 受入基準（要約。テストとの対応は `plan.md` §6）

### BE（jest で自動検証）

- AC-AV-01 `GET /v1/me` はアバター未設定なら `profile.avatar_url: null`
- AC-AV-02 設定済みなら `profile.avatar_url` = `<AVATAR_PUBLIC_BASE_URL>/<object_key>`
- AC-AV-03 `user_avatars` が存在しない（`P2021`）とき `GET /v1/me` は 200・`avatar_url: null`
- AC-AV-04 JPEG を `PUT` すると 200・`MeView` に新 URL。保存されたのは 512×512 の JPEG、キーは `avatars/<uuid>.jpg`（userId を含まない）、`Cache-Control: private, max-age=31536000, immutable`
- AC-AV-05 PNG（透過含む）も受理され JPEG 512×512 で保存される
- AC-AV-06 非正方形・EXIF 回転付き JPEG は向きを適用して中央クロップされる。出力に EXIF が無い
- AC-AV-07 HEIC / GIF / テキストは 415 `UNSUPPORTED_MEDIA_TYPE`（`Content-Type: image/jpeg` と偽っても）。ストレージは呼ばれない
- AC-AV-08 5MiB 超は 413 `PAYLOAD_TOO_LARGE`。ストレージは呼ばれない
- AC-AV-09 `file` 欠落・複数ファイル・未知フィールドは 400 `VALIDATION_ERROR`
- AC-AV-10 壊れた JPEG / ピクセル上限超過は 400 `VALIDATION_ERROR`
- AC-AV-11 置換時、DB 更新後に旧オブジェクトが削除される。旧削除の失敗でも 200
- AC-AV-12 DB 更新失敗時は新オブジェクトが補償削除され 500
- AC-AV-13 `AVATAR_BUCKET` 未設定で `PUT` は 503 `SERVICE_UNAVAILABLE`、DB・ストレージに触れない
- AC-AV-14 `DELETE /v1/me/avatar` は行とオブジェクトを消し 200 `avatar_url: null`。未設定でも 200
- AC-AV-15 未認証は 401。2 ハンドラに `@Public()` が無い
- AC-AV-16 `PUT` / `DELETE` は userId 単位 10 回 / 5 分で 429、他ルート・他ユーザーに波及しない
- AC-AV-17 アカウント削除でアバターのオブジェクトが削除される。削除失敗でも 204
- AC-AV-18 `user_avatars` 不在時、`PUT` / `DELETE` は 503（`PUT` はストレージにアップロードする**前に**判定）
- AC-AV-19 新しい環境変数が `docker-compose.yml` に揃っている（既存 `env-coverage.spec.ts` が緑）
- AC-AV-20 413 / 415 / 503 が契約のエラーコードに写る（`errorCodeFromStatus`・`ERROR_CODE_STATUS`）

### iOS（ビルドゲート + 手動確認。Domain / Networking / Core は XCTest を追加）

- AC-AV-30 `MeProfileResponse` が `avatar_url` の有無・`null` の両方をデコードできる（Networking テスト）
- AC-AV-31 multipart の body が契約どおり（境界・`name="file"`・`Content-Type: image/jpeg`）。`Endpoint` が `Content-Type` を上書きできる（Networking テスト）
- AC-AV-32 端末変換: 任意サイズ・向きの画像が 512×512 JPEG になる（Core テスト）
- AC-AV-33 `ProfileStore.uploadAvatar` / `deleteAvatar` が成功で `profile` を差し替え、失敗で `errorMessage` を立て `profile` を変えない（Domain テスト）
- AC-AV-34-M アカウント設定で写真を選ぶ → プレビュー → 使う → カードに反映、アプリ再起動後も表示
- AC-AV-35-M 写真を削除 → 確認 → イニシャル表示に戻る
- AC-AV-36-M ホーム左上の入口にアバターが出る / 未設定ならアイコン
- AC-AV-37-M HEIC の写真（iPhone 標準カメラ）を選んでも成功する
- AC-AV-38-M 名義一覧・名義詳細・共有プレビューのアバターの見た目が変わっていない
- AC-AV-39-M 機内モードで送信 → エラーバー、表示は変更前のまま
