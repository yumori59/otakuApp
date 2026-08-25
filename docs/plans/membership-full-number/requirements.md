# membership-full-number — Requirements

FC 会員番号を**下4桁ではなく全桁で保存し、常時全桁を表示する**。

- 前提となる論点と暫定回答: `questions-requirements.md`（Q1=共有マスキング維持 / Q2=`mask_member_no` は残す / Q3=リネーム / Q4=既存値をそのまま移す（未出荷前提）/ Q5=互換不要 / Q6=単純改名 / Q7=長さと制御文字のみ制限 / Q8=撤回を記録して書き換え / Q9=残存リスク受容）
- **Q1 と Q4 は実装前に人間の確認が必須**（後述 §0）。他は回答が異なれば本ファイルと `plan.md` を先に直す

## 0. 背景 — この変更は既存のプライバシー / コンプライアンス設計の撤回である

本要件は機能追加ではなく、**明文化済みの設計決定の撤回**である。実装前にこの節を読むこと。

2026-08-20、ユーザーに以下の 2 択を提示した:

- 会員番号を暗号化保存し、既定は下4桁表示（現行設計の維持）
- **会員番号の全桁を平文で保存し、常時表示する** ← 選択された

選択肢の提示時に「これは現在のコンプラ設計（C3・他人の機微情報を平文で持つリスク回避）を撤回することになる。
関連ドキュメントの見直しも必要」と明記しており、**ユーザーはその説明を理解した上で後者を選んだ**。

### 撤回される決定

| # | 撤回対象 | 出所 |
|---|---|---|
| W1 | C3「会員番号を暗号化保存 + 既定で下4桁表示に変更（他人の機微情報を平文で持つリスクを排除）」 | `docs/01-product-overview.md:295` |
| W2 | P6「機微情報（FC会員番号）は暗号化して保存し、表示用に下4桁のみ平文で持つ」 | `docs/03-database.md:61` |
| W3 | 「会員番号のみ E2EE」という §2.3 の中心的な設計判断 | `docs/08-compliance-risk.md:320-357` |
| W4 | 対策表 3「暗号化保存と下4桁表示 / `No. ****4821` / タップで 3 秒だけ全桁」 | `docs/08-compliance-risk.md:282` |
| W5 | ユーザー向け説明文面「登録した情報は暗号化して保存され、下4桁のみ表示されます」 | `docs/08-compliance-risk.md:307` |
| W6 | リリース前チェック「全桁表示はタップ後3秒だけ」 | `docs/08-compliance-risk.md:629` |
| W7 | R20 の対策から「下4桁表示」 | `docs/08-compliance-risk.md:790` |
| W8 | ロードマップ 0-13「会員番号の暗号化保存」2.0 人日 | `docs/09-roadmap.md:82` |
| W9 | App Privacy 申告「収集する（暗号化保存、下4桁表示）」 | `docs/12-app-store-release.md:82` |
| W10 | 設計基盤の「機微情報として暗号化保存、既定では下4桁のみ表示」 | `docs/00-design-basis.md:147,176` |
| W11 | 「入力を任意とし『会員番号を保存しない』選択ができるようにする」 | `docs/03-database.md:373` |

### 撤回の実体（誤解しやすい点）

**暗号化はまだ 1 行も実装されていない。** `member_no_cipher` 列は設計 DDL の中だけに存在し、
実在するのは `member_no_last4` だけである（`schema.prisma:131` / `docs/04-api.md:229` D7）。

したがって実際に撤回されるのは:

1. **実装済み**: 下4桁への切り詰め（iOS の `prefix(4)` と BE の 1〜4 文字バリデーション）
2. **未実装（計画のみ）**: 暗号化保存（ロードマップ 0-13 の 2.0 人日）

### 撤回しないもの

- **共有時のマスキング**（Q1=A）。共有ボードのペイロードは会員番号を構造的に含まず、
  spec が禁止キーとして検査している（`resolve-share.use-case.spec.ts:219-221`）。
  この保証は**維持する**。全桁平文になるのは**オーナー本人の画面と本人のデータだけ**。

### 受容される残存リスク

- `docs/08-compliance-risk.md:790` の R20（端末紛失時の第三者情報の閲覧）は、
  対策から「下4桁表示」が外れることで悪化する。代替対策（App Switcher のブラー / アプリロック）は
  Phase 1 のままで、本計画では実装しない。
- 「他人の機微情報を平文で預かる」状態になるため、`docs/08` の法務確認項目に
  「会員番号の平文保存についての確認」を追加する（Q9）。

## 1. 用語の確定

| 語 | 実体 | 根拠 |
|---|---|---|
| 「会員番号」 | `Membership.memberNoLast4` / `memberships.member_no_last4` | `schema.prisma:131` |
| 「全桁」 | FC が発行した番号そのまま（`STL-04821` のような英数記号混在を含む） | `docs/03-database.md:371` |
| 「常時表示」 | 名義詳細の `MembershipCard` に、タップやマスクを介さず表示する | `FormComponents.swift:221-250` |

## 2. 機能要件

| ID | 要件 |
|---|---|
| FR-MN-1 | 会員番号は全桁で保存する。DB の列名を `member_no_last4` → `member_no` にリネームする（Q3-A） |
| FR-MN-2 | API のフィールド名を `member_no_last4` → `member_no` に変更する（POST / PATCH / GET / sync push / sync pull の全経路） |
| FR-MN-3 | BE のバリデーションを「1〜4 文字の英数」から「1〜64 文字・制御文字を含まない文字列」に変更する（Q7-A） |
| FR-MN-4 | iOS の入力欄から**下4桁への黙った切り捨て（`prefix(4)`）を撤去**する。上限は 64 文字で、超過分は切り捨てではなく入力不可とする |
| FR-MN-5 | iOS の入力欄ラベルを「会員番号の下4桁（任意）」から「会員番号（任意）」に変更する。プレースホルダも全桁の例に変える |
| FR-MN-6 | 名義詳細（`MembershipCard`）は会員番号を全桁で常時表示する。マスク・タップで一時表示・3 秒タイマーは実装しない |
| FR-MN-7 | 会員番号は引き続き**任意**。未入力なら `null` を保存し、表示行自体を出さない（現状どおり） |
| FR-MN-8 | 既存データ（下4桁のみ保存済み）は値をそのまま `member_no` に引き継ぐ。全桁の復元はしない（Q4-A） |
| FR-MN-9 | **共有ボードのペイロードには会員番号を含めない**（現状維持）。`resolve-share` / `update-share-item` の禁止キー検査は `member_no` / `member_no_last4` の両方を維持する |
| FR-MN-10 | `share_links.mask_member_no` は削除せず現状のまま残す。`docs/04-api.md` に「board ペイロードに会員番号が含まれないため、このフラグは現状 board の内容に影響しない」旨を注記する（Q2-A） |
| FR-MN-11 | `docs/00` / `01` / `03` / `04` / `05` / `07` / `08` / `09` / `12` の該当記述を、**撤回の事実（日付・理由）を残した形で**現行仕様に書き換える（Q8-B） |
| FR-MN-12 | ロードマップ 0-13（暗号化保存 2.0 人日）を撤回済みとし、Phase 0 合計工数を更新する。0-17 のテスト項目から「暗号化の往復」を外す |

## 3. 非機能要件・制約

| ID | 内容 |
|---|---|
| NFR-1 | API 契約 3 層（`schema.prisma` ↔ NestJS dto/service/presenter ↔ iOS Domain/Networking/DataStore）を**同時に**変える。片側だけ変えない |
| NFR-2 | 書き込みの主経路は `POST /v1/sync/push`（`sync-payload.mapper.ts:44`）。REST の POST/PATCH と**両方**を変更する（BE-9: 書き込み経路が 2 本ある） |
| NFR-3 | `sync/push` の `payload` は未知キーを黙って無視する（`sync.dto.ts:30-31`）。改名によって値が黙って消える経路が生まれないことを確認する |
| NFR-4 | BE の振る舞い変更はテスト先行（Red→Green）。`cd apps/api && npm test` を完了ゲートにする |
| NFR-5 | iOS は `swift test --package-path` が通る 3 パッケージ（Domain / Networking / DataStore）で該当テストを更新し、`xcodebuild` BUILD SUCCEEDED を完了ゲートにする |
| C-1 | 全桁は**復元不可能**。移行で「元の番号」を取り戻すことはできない |
| C-2 | `member_no_cipher` は実装しない（今回で計画ごと撤回される） |
| C-3 | Prisma の列リネームを `prisma db push` で行うと drop + add になり値が消える。値を残すなら先に `ALTER TABLE ... RENAME COLUMN` を明示的に流す（`plan.md` T1 の手順） |
| C-4 | 本番 DB / TestFlight 配布済み端末の有無が未確認（Q4）。**「無い」ことを確認するまで破壊的移行を実行しない** |

## 4. スコープ外

- 会員番号の暗号化（撤回のため実装しない）
- 共有先への会員番号開示（Q1=A。B なら本計画をやり直す）
- `mask_member_no` 列 / フィールドの削除（Q2-A）
- App Switcher のブラー・アプリロックなど R20 の代替対策の実装
- FC マスタ表（`fan_clubs` / `fan_club_id`）の実装
- 会員情報の削除 UI・編集 UI（別計画）

## 5. 受入基準

| AC-ID | 受入基準 | 検証方法 |
|---|---|---|
| AC-MN-01 | `POST /v1/memberships` に `member_no: "STL-04821"` を渡すと 201 で保存され、レスポンスに全桁が返る | `apps/api` jest |
| AC-MN-02 | `POST /v1/memberships` に `member_no_last4` を渡すと 400（`property member_no_last4 should not exist`） | jest |
| AC-MN-03 | `member_no` が 65 文字以上なら 400 | jest |
| AC-MN-04 | `member_no` に制御文字（`\n` / ` `）を含むと 400 | jest |
| AC-MN-05 | `member_no` 省略時は `null` が保存される。`null` を明示した PATCH でクリアできる | jest |
| AC-MN-06 | `PATCH /v1/memberships/:id` で `member_no` だけを更新できる（他フィールドが変わらない） | jest |
| AC-MN-07 | `POST /v1/sync/push` の memberships payload の `member_no` が保存される | jest |
| AC-MN-08 | `POST /v1/sync/pull` のレスポンスに `member_no` が含まれ、`member_no_last4` は含まれない | jest |
| AC-MN-09 | 共有ボードのペイロードに `member_no` / `member_no_last4` のいずれも現れない（既存の禁止キー検査が通り続ける） | jest（既存 spec の維持確認） |
| AC-MN-10 | iOS の `MembershipDTO` が `member_no` を往復できる（デコード / エンコード） | NetworkingTests |
| AC-MN-11 | `MembershipRecord` の sync payload が `member_no` キーで出力され、`member_no` を読み込める。未設定時は `.null` | DataStoreTests |
| AC-MN-12 | 会員情報追加フォームに 20 文字の番号を入力しても切り捨てられない | 手動確認 |
| AC-MN-13 | 名義詳細の会員情報カードに全桁が常時表示される（マスク無し・タップ不要） | 手動確認 |
| AC-MN-14 | 会員番号未入力の会員情報は、カードに `No.` 行自体が出ない | 手動確認 |
| AC-MN-15 | 共有プレビュー / 共有ボードのどこにも会員番号が出ない | 手動確認 |
| AC-MN-16 | 撤回された docs 記述（W1〜W11）がすべて現行仕様に更新され、撤回日と理由が残っている | レビュー |
