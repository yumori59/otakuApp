# membership-full-number — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。

> **着手前の必須確認（2 点）— 確定済み（2026-08-20 ユーザー確認）**
> 1. **Q1**: 共有時のマスキングを維持する（＝共有先には会員番号を出さない）→ **A（維持）を確定**
> 2. **Q4**: 本番 DB / TestFlight 配布済み端末に守るべき会員番号データが存在するか → **未配布（開発中のみ）を確定**。Q4=C（開発 DB を作り直す）・Q5=A（互換対応不要）・Q6=A（単純改名）を採用する。
>
> 上記が確定したため T1（スキーマ変更）に着手してよい。

## 0. 現状把握（ギャップ分析）

| 層 | 現状 | 変更 |
|---|---|---|
| DB | `memberships.member_no_last4 text`（`schema.prisma:131`）。`member_no_cipher` は**存在しない**（設計 DDL のみ） | 列リネーム 1 本 |
| BE DTO | `create-membership.dto.ts:14,36-40` / `update-membership.dto.ts:36-38` が `/^[0-9A-Za-z]{1,4}$/` | フィールド名 + 検証を変更 |
| BE Service | `memberships.service.ts:15,78,109-110,184`（型・create・update・presenter） | 4 箇所 |
| BE Sync | `sync-serialize.ts:34`（pull）/ `sync-payload.mapper.ts:44`（push） | 2 箇所。**両方必須**（BE-9） |
| BE Shares | `resolve-share.use-case.spec.ts:219-221` / `update-share-item.use-case.spec.ts:481` の禁止キーに `member_no` と `member_no_last4` が**既に両方入っている** | **変更なし**（そのまま通ることを確認するだけ） |
| iOS Networking | `MembershipDTO.swift:18,32,51,62,75,85,97,114,131,147`（response / create / patch の 3 DTO） | 全て |
| iOS DataStore | `MembershipRecord.swift:13,29,44` / `+Mapping.swift:11,27,39,51` / `+SyncPayload.swift:11,32,53,96` | 全て |
| iOS Domain | `Models.swift:49,60,70` / `Patches.swift:19` / `IdentityStore.swift:191,198` / `Preview/SampleData.swift:83-91` / `Preview/InMemoryRepositories.swift:60` | 全て |
| iOS DesignSystem | `FormComponents.swift:224,231,233,244-245`（`MembershipCard`） | プロパティ名 + コメント |
| iOS Features | `AddMembershipView.swift:15-16,36-42,91,96`（**`prefix(4)` の切り捨てはここ**）/ `IdentityDetailView.swift:126` | 入力制限の撤去 + ラベル |
| iOS Tests | `MembershipDTOTests.swift:17,32,46,66,71` / `SwiftDataMembershipRepositoryTests.swift:21,63,74` / `SyncEngineCollectionsTests.swift:91,144` | 全て |
| BE Tests | `memberships.service.spec.ts:19` / `create-membership.dto.spec.ts:46-58`（AC-MB-04） | 全て |
| docs | W1〜W11（`requirements.md` §0） | 撤回記録付きで書き換え |

**結論**: 新機能の追加ではなく **1 フィールドの意味変更が 3 層 + 同期 2 経路 + docs 9 ファイルに波及する**タスク。
実装量は小さいが、**取りこぼすと黙ってデータが消える**類（NFR-3）なので網羅性が全て。

## 1. 設計判断

### D-1 列は「リネーム」。併存も名前据え置きもしない

- 採用: `member_no_last4` → `member_no`（Prisma: `memberNoLast4` → `memberNo`）。
- 却下 a: 列名据え置きで中身だけ全桁にする。→ 列名が事実と食い違い、以後の全レビューで誤読される。
- 却下 b: `member_no` を新設して `member_no_last4` を残す。→ 同じ意味の値が 2 列になり、
  同期・LWW・表示のどこかでズレても検知できない。`feedback_review_patterns.md` BE-9（書き込み経路が 2 本）の変種。

### D-2 バリデーションは長さと制御文字だけ。文字種を絞らない

- 採用: `@IsString() @MinLength(1) @MaxLength(64)` + `@Matches(/^[^\p{Cc}\p{Cf}]+$/u)`（制御文字・書式文字を拒否）。
- 却下: `/^[0-9A-Za-z\-_/. ]{1,64}$/`。→ 全角文字や FC 固有の記号を含む番号を 400 で弾く。
  会員番号は検索も集計もしない項目（`docs/08-compliance-risk.md:356`）なので、文字種を絞る実利が無い。
- **黙って切らない**（BE-2）。長すぎれば 400 を返す。

### D-3 iOS の `prefix(4)` は撤去する

`AddMembershipView.swift:38-41` は 5 文字目以降を**黙って捨てている**。これは BE-2（黙殺フォールバック）の iOS 版で、
今回の変更の本体でもある。上限 64 文字は「超えたら入力を受け付けない」形にし、切り捨てにはしない。

### D-4 共有マスキングは「何もしない」ことで維持される

board ペイロードはそもそも会員番号を組み立てていない。禁止キー検査（`resolve-share.use-case.spec.ts:219-221`）は
`member_no` を既に含むので、**新しい列名でも自動的に守られる**。
このタスクでは `apps/api/src/shares/` を 1 行も触らない。触っていないことをレビューで確認する。

### D-5 docs は削除ではなく「撤回の記録」

- 採用: 各所を現行仕様に書き換えたうえで、`docs/08-compliance-risk.md` に
  「2026-08-20 ユーザー判断により撤回。残存リスクは R20 として受容」を明記する。
- 却下: 該当記述を消す。→ リスク管理台帳から対策が消えるだけになり、「なぜ対策が無いのか」の経緯が失われる。
  次のレビューまたは法務確認で同じ議論が再燃する。

### D-6 テストは BE 側を厚く、iOS は既存テストの追従に留める

振る舞い（検証・保存・同期の往復）は全て BE で決まるので、Red→Green は `apps/api` で行う。
iOS 側は既存の DTO / Repository / SyncEngine テストのフィールド名追従が主で、新しい振る舞いテストは足さない。

## 2. API 契約（**実装エージェントはこの表を正とする**）

### 2.1 変更の要旨

| 旧 | 新 |
|---|---|
| `member_no_last4`（1〜4 文字の英数、`null` 可） | `member_no`（1〜64 文字、制御文字禁止、`null` 可） |

`member_no_last4` は**どの経路でも受理しない**（`forbidNonWhitelisted` により REST では 400、
sync push では無視される — この差は NFR-3 として T3 で確認する）。

### 2.2 `POST /v1/memberships`

```jsonc
// req
{
  "id": "018f3c2a-bbbb-7c90-9d2a-000000000001",
  "identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
  "fan_club_name_raw": "STELLARIS OFFICIAL FAN CLUB",
  "member_no": "STL-04821",        // 変更: 旧 member_no_last4。1〜64文字・制御文字不可・省略可・null 可
  "rank": "プレミアム",
  "renewal_on": "2026-09-15",
  "fee_yen": 5500,
  "auto_renew": false,
  "note": null
}
// 201 res — 同じ形 + created_at / updated_at / deleted_at
```

- `member_no_last4` / `member_no_cipher` / `fan_club_id` は**受理しない**（400）
- 検証: `@IsOptional() @IsString() @MinLength(1) @MaxLength(64) @Matches(/^[^\p{Cc}\p{Cf}]+$/u)`
- エラーコード・envelope は既存のまま（`VALIDATION_ERROR` / 400）

### 2.3 `PATCH /v1/memberships/:id`

```jsonc
{ "member_no": "STL-04821" }   // 更新
{ "member_no": null }          // クリア
```

`member_no` を省略すれば無変更（既存の Patchable セマンティクスを維持）。

### 2.4 `GET /v1/memberships` / `GET /v1/memberships?identity_id=`

要素は 2.2 の 201 レスポンスと同形。`member_no_last4` キーは**返さない**。

### 2.5 `POST /v1/sync/push` — memberships payload

```jsonc
{
  "collection": "memberships",
  "op": "upsert",
  "id": "<uuid>",
  "updated_at": "2026-08-20T10:00:00.000Z",
  "payload": {
    "identity_id": "<uuid>",
    "fan_club_name_raw": "STELLARIS OFFICIAL FAN CLUB",
    "member_no": "STL-04821",     // 変更: 旧 member_no_last4。null 可
    "rank": null,
    "renewal_on": "2026-09-15",
    "fee_yen": 5500,
    "auto_renew": false,
    "note": null,
    "deleted_at": null
  }
}
```

`sync-payload.mapper.ts` は `memberNo: payload.member_no ?? null` にする。
**Q4 で「配布済み端末あり」と判明した場合のみ**、移行期間中は `payload.member_no ?? payload.member_no_last4 ?? null` にする（Q5-B）。

### 2.6 `POST /v1/sync/pull`

`sync-serialize.ts` の memberships 要素で `member_no: row.memberNo`。`member_no_last4` は出力しない。

### 2.7 共有（**変更なし**）

`GET /v1/shares/received/:id` / board ペイロードは従来どおり会員番号を含まない。
`share_links.mask_member_no` は現状のまま（`docs/04-api.md` に「board ペイロードに会員番号が無いため、
このフラグは現状 board の内容に影響しない」の注記だけ追加）。

### 2.8 Prisma

```prisma
model Membership {
  // ...
  memberNo       String?   @map("member_no")   // 旧: memberNoLast4 @map("member_no_last4")
  // ...
}
```

`db push` 前に既存値を残すなら §3 T1 の手順に従うこと。

### 2.9 iOS 側の対応表

| 層 | 旧 | 新 |
|---|---|---|
| `Domain/Models/Models.swift` | `Membership.memberNoLast4: String?` | `Membership.memberNo: String?` |
| `Domain/Models/Patches.swift` | `MembershipPatch.memberNoLast4` | `MembershipPatch.memberNo` |
| `Domain/Stores/IdentityStore.swift` | `addMembership(..., memberNoLast4:, ...)` | `addMembership(..., memberNo:, ...)` |
| `Networking/DTO/MembershipDTO.swift` | `memberNoLast4` / CodingKey `member_no_last4` | `memberNo` / CodingKey `member_no` |
| `DataStore/Models/MembershipRecord*.swift` | `memberNoLast4` / payload キー `member_no_last4` | `memberNo` / `member_no` |
| `DesignSystem/FormComponents.swift` | `MembershipCard(memberNoLast4:)` | `MembershipCard(memberNo:)` |

## 3. 実装タスク

### T1 (DB / BE) スキーマと REST 契約 — **テスト先行 (Red→Green)**

担当候補: `nest-developer`

**手順（順序厳守）**

1. **Q4 の回答を確認**。守るべきデータがあるなら、先に手で
   `ALTER TABLE memberships RENAME COLUMN member_no_last4 TO member_no;` を対象 DB に流す
   （`prisma db push` の列リネームは drop + add になり値が消えるため — C-3）。
   無いなら手順 2 から。
2. `apps/api/prisma/schema.prisma:131` を `memberNo String? @map("member_no")` に変更
3. `cd apps/api && npx prisma db push`（**必ず `apps/api/` で** — BE-5）
4. DTO spec を Red にしてから DTO を変更:
   - `apps/api/src/memberships/dto/create-membership.dto.spec.ts`（`AC-MB-04` の 3 ケースを AC-MN-02/03/04 に置き換え）
   - `create-membership.dto.ts` / `update-membership.dto.ts`（D-2 の検証へ）
   - **DTO spec は素の `validate(dto)` ではなく whitelist 付きで検証すること**（BE-8。既存 spec の `validateBody` ヘルパを使う）
5. `memberships.service.ts:15,78,109-110,184` を追従（型 / create / update / presenter）
6. `memberships.service.spec.ts:19` ほかを追従

**追加テスト（Red 先行）**

| AC-ID | 内容 |
|---|---|
| AC-MN-01 | `member_no: "STL-04821"` が保存され、レスポンスに全桁が返る |
| AC-MN-02 | `member_no_last4` を渡すと `property member_no_last4 should not exist` で 400 |
| AC-MN-03 | 65 文字で 400 |
| AC-MN-04 | 制御文字（`\n`）を含むと 400 |
| AC-MN-05 | 省略時 `null` / PATCH `null` でクリア |
| AC-MN-06 | PATCH で `member_no` だけ更新され他が変わらない |

**やらないこと**: `apps/api/src/shares/` と `apps/api/src/sync/` は触らない（T2 の担当。同一ファイル衝突を避ける）。

---

### T2 (BE) 同期 2 経路の追従 — **テスト先行 (Red→Green)**

担当候補: `nest-developer`（**T1 完了後**。`schema.prisma` を共有するため直列）

1. `apps/api/src/sync/sync-payload.mapper.ts:44` — `memberNo: payload.member_no ?? null`
2. `apps/api/src/sync/sync-serialize.ts:34` — `member_no: row.memberNo`
3. spec 追加:

| AC-ID | 内容 |
|---|---|
| AC-MN-07 | push の memberships payload の `member_no` が保存される |
| AC-MN-08 | pull のレスポンスに `member_no` が含まれ `member_no_last4` が含まれない |
| AC-MN-09 | `resolve-share` / `update-share-item` の禁止キー検査が**変更なしで通る**（回帰確認） |

**重要（NFR-3 の確認項目）**: `sync.dto.ts:30-31` の `payload` は `@IsObject()` なので、
旧キー `member_no_last4` を送っても **400 にならず黙って無視される**。
Q4 で「配布済み端末なし」を確認できている場合はこれで問題ないが、
**確認できていないなら T2 に着手しない**（黙って会員番号が消える経路になる）。

**やらないこと**: `apps/api/src/shares/` は 1 行も変更しない（D-4）。

---

### T3 (iOS) 3 パッケージの契約追従

担当候補: `swift-developer`（**T1 の API 契約確定後。T2 と並列可**）

1. `Domain`: `Models.swift:49,60,70` / `Patches.swift:19` / `IdentityStore.swift:191,198` / `Preview/SampleData.swift:83-91` / `Preview/InMemoryRepositories.swift:60`
   - `SampleData` の値は下4桁風（`"4821"`）から全桁風（`"STL-04821"`）に更新して、プレビューで全桁表示が確認できるようにする
2. `Networking`: `MembershipDTO.swift` の 3 DTO（response / create / patch）と CodingKeys
   - `MembershipDTOTests.swift:17,32,46,66,71` を `member_no` に更新（AC-MN-10）
3. `DataStore`: `MembershipRecord.swift` / `+Mapping.swift` / `+SyncPayload.swift`
   - SwiftData プロパティは Q6 の回答に従う。**未出荷なら単純改名、配布済みなら `@Attribute(originalName: "memberNoLast4")`**
   - `SwiftDataMembershipRepositoryTests.swift:21,63,74` / `SyncEngineCollectionsTests.swift:91,144` を更新（AC-MN-11）

**完了条件**:
```bash
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/Networking
swift test --package-path meigicho/Packages/DataStore
```

**やらないこと**: `Features` / `DesignSystem` は T4 の担当（同一ファイル衝突を避ける）。

---

### T4 (iOS) 入力制限の撤去と全桁表示

担当候補: `swift-developer`（**T3 完了後**）

1. `DesignSystem/Components/FormComponents.swift:221-250`
   - `MembershipCard.memberNoLast4` → `memberNo`。ドキュメンテーションコメント「平文の全桁は保持しない」を削除し、
     現行仕様（全桁を保持・表示）に書き換える
   - 表示は `Text("No. \(memberNo)")` のまま（マスク処理は入れない）
   - 長い番号でレイアウトが崩れないよう `.lineLimit(1)` + `.truncationMode(.middle)` を検討する
2. `Features/Forms/AddMembershipView.swift`
   - `:15-16` プロパティ名とコメントを更新（「下 4 桁だけ保持する（`contract-mapping.md` §3.2 / C5）」は撤回済みなので書き換える）
   - `:36-42` **`prefix(4)` と英数フィルタを撤去**。上限 64 文字で入力打ち止め（切り捨てではない）
   - `:36` ラベルを「会員番号（任意）」、プレースホルダを「例）STL-04821」に
   - `:91,96` 保存処理のフィールド名追従
3. `Features/Detail/IdentityDetailView.swift:126` — 引数名追従

**完了条件**: `xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build` が BUILD SUCCEEDED。

**手動確認手順**

| # | 操作 | 期待 | AC-ID |
|---|---|---|---|
| 1 | 会員情報追加で `STL-04821-EXTRA-LONG`（20 文字）を入力 | 切り捨てられずそのまま入る | AC-MN-12 |
| 2 | 保存して名義詳細を開く | カードに全桁が常時表示される（マスク無し・タップ不要） | AC-MN-13 |
| 3 | 会員番号を空欄で保存 | カードに `No.` 行が出ない | AC-MN-14 |
| 4 | 共有プレビューを開き、共有を作って受信箱から board を開く | どこにも会員番号が出ない | AC-MN-15 |
| 5 | 機内モードで会員番号を編集 → 復帰 → 別端末（または pull）で確認 | 全桁が同期されている | AC-MN-07/08 の縦串確認 |

---

### T5 (docs) 撤回の記録と仕様更新

担当候補: planner セッションまたは `swift-developer`（**T1〜T4 と並列可**）

| ファイル | 変更内容 |
|---|---|
| `docs/00-design-basis.md:147` | 「機微情報として暗号化保存、既定では下4桁のみ表示。共有時はマスキング既定」→「全桁を平文で保存し常時表示（2026-08-20 ユーザー判断で暗号化・下4桁表示を撤回）。**共有時のマスキングは維持**」 |
| `docs/00-design-basis.md:176` | L2 リスクの対策から「会員番号の暗号化、下4桁表示」を外し、「共有時マスキング既定」のみ残す。撤回の注記を添える |
| `docs/01-product-overview.md:295`（C3） | 撤回済みとして書き換え。「2026-08-20 撤回。理由: 利用者が自分の会員番号を確認できないため」 |
| `docs/01-product-overview.md:251` | 「会員番号は暗号化保存」を削除。共有のトークン/失効の記述は残す |
| `docs/01-product-overview.md:104`（R4-6） | **変更しない**（共有マスキングは維持） |
| `docs/03-database.md:61`（P6） | 撤回済みとして書き換え |
| `docs/03-database.md:133-134` | ER 図から `member_no_cipher` を削除し `member_no` に改名 |
| `docs/03-database.md:342-343` | DDL から `member_no_cipher` を削除。`member_no text` に変更（`length <= 4` の check を外す） |
| `docs/03-database.md:370-373` | 「会員番号の扱い（重要）」節を全面書き換え。撤回の事実・日付・残存リスクを記載。W11（保存しない選択肢）も撤回として明記 |
| `docs/04-api.md:220,229` | `member_no_last4` → `member_no`。「1〜4文字の英数」→「1〜64文字・制御文字不可」。`member_no_cipher` を受理しない旨は残す |
| `docs/04-api.md:440,452,473` 付近 | `mask_member_no` に「board ペイロードに会員番号が含まれないため、現状このフラグは board の内容に影響しない」注記を 1 行追加（FR-MN-10） |
| `docs/05-ios-client.md:178` | `memberNoCipher: Data?` を削除、`memberNoLast4` → `memberNo` |
| `docs/07-monetization.md:78,798` | 「会員番号の保存・下4桁表示」→「会員番号の保存・表示」 |
| `docs/08-compliance-risk.md:215` | ユーザー向け説明を現行仕様へ |
| `docs/08-compliance-risk.md:282`（対策 3） | 「**2026-08-20 撤回**（ユーザー判断）。会員番号は全桁を平文で保存・表示する。残存リスクは R20 で受容」に書き換え |
| `docs/08-compliance-risk.md:284`（対策 5） | **変更しない**（共有マスキングは維持） |
| `docs/08-compliance-risk.md:307` | **説明文面の書き換え必須**。「暗号化して保存され、下4桁のみ表示されます」→ 実装と一致する文面に |
| `docs/08-compliance-risk.md:320-357`（§2.3 / E2EE 判断） | 会員番号の行を撤回。§2.3 の「会員番号のみ E2EE」という結論部分は、撤回した事実と日付を残したうえで結論を差し替える |
| `docs/08-compliance-risk.md:629` | リリース前チェック「全桁表示はタップ後3秒だけ」を削除 |
| `docs/08-compliance-risk.md:790`（R20） | 対策から「下4桁表示」を削除。評価を見直し、残存リスクとして受容する旨を記載 |
| `docs/08-compliance-risk.md`（法務確認の節） | 「会員番号の平文保存についての法務確認」を必須項目に追加（Q9） |
| `docs/09-roadmap.md:82`（0-13） | 撤回として取り消し線 + 理由。**2.0 人日を Phase 0 合計から減算** |
| `docs/09-roadmap.md:86`（0-17） | テスト項目から「暗号化の往復」を削除 |
| `docs/09-roadmap.md:44` | Phase 0 のスコープ列から「会員番号の暗号化」を削除 |
| `docs/12-app-store-release.md:82` | App Privacy 申告を「収集する（**平文保存・アプリ内で本人にのみ表示**）」に書き換え。**申告と実装の不一致は審査リスク**なので必ず更新 |
| `CLAUDE.md` の既知の未整備 | 「本番運用前に必須」に「会員番号の平文保存についての法務確認」を追加 |

**やらないこと**: `docs/06-infrastructure.md:449`（共有リンクのマスキング）は変更しない。

---

## 4. 並列実行可能なタスク

| 並列グループ | タスク | 理由 |
|---|---|---|
| 直列（必須） | **T1 → T2** | `schema.prisma` と Prisma クライアント型を共有する |
| 直列（必須） | **T3 → T4** | `Domain.Membership` の型に依存する |
| 並列 A | **T2** と **T3** | BE の sync と iOS のパッケージ。ファイルが重ならない（T1 完了後） |
| 並列 B | **T5**（docs）はいつでも | 実装ファイルに触らない |

**同時に走らせてはいけないもの**

- `apps/api/prisma/schema.prisma` は T1 のみ
- `MembershipDTO.swift` / `MembershipRecord*.swift` は T3 のみ
- `docs/09-roadmap.md` は T5 のみ（`identity-grouping` 計画の T3 も同ファイルを触る。**どちらか一方ずつ**）

**API 契約は §2 で確定済み**なので、T2（BE）と T3（iOS）は契約未確定のまま並列にはならない（`.claude/rules/03-parallel-development.md`）。

## 5. 受入基準 → テストケース対応

| AC-ID | 種別 | 置き場所 |
|---|---|---|
| AC-MN-01 | 自動 | `apps/api/src/memberships/memberships.service.spec.ts`（T1・Red 先行） |
| AC-MN-02/03/04 | 自動 | `apps/api/src/memberships/dto/create-membership.dto.spec.ts`（T1・**whitelist 付き検証** BE-8） |
| AC-MN-05/06 | 自動 | `memberships.service.spec.ts`（T1） |
| AC-MN-07 | 自動 | `apps/api/src/sync/` の push spec（T2） |
| AC-MN-08 | 自動 | `apps/api/src/sync/` の pull / serialize spec（T2） |
| AC-MN-09 | 自動（回帰） | `resolve-share.use-case.spec.ts` / `update-share-item.use-case.spec.ts`（**変更せずに通ること**を確認） |
| AC-MN-10 | 自動 | `meigicho/Packages/Networking/Tests/NetworkingTests/MembershipDTOTests.swift`（T3） |
| AC-MN-11 | 自動 | `meigicho/Packages/DataStore/Tests/DataStoreTests/SwiftDataMembershipRepositoryTests.swift` / `SyncEngineCollectionsTests.swift`（T3） |
| AC-MN-12 〜 15 | 手動 | T4 の手動確認手順 1〜5 |
| AC-MN-16 | レビュー | `code-reviewer` が W1〜W11 の全箇所を突き合わせる |

## 6. エッジケース

| # | ケース | 扱い |
|---|---|---|
| E-1 | 既存行が下4桁だけ持っている | そのまま `member_no` として残る（FR-MN-8）。全桁復元はしない。UI 上は「4821」と表示され、ユーザーが上書きできる |
| E-2 | `member_no` が空文字 | `@MinLength(1)` で 400。iOS はトリム後に空なら `nil` を送る（現状の `AddMembershipView.swift:91,96` と同じ） |
| E-3 | 前後空白付きの入力 | iOS 側でトリムしてから送る（現状どおり）。BE はトリムしない |
| E-4 | 旧クライアントが `member_no_last4` を sync push で送る | **黙って無視され値が消える**（`sync.dto.ts:30-31`）。Q4 で配布済みと判明したら Q5-B の互換受理が必須 |
| E-5 | 旧クライアントが `member_no_last4` を REST POST で送る | `forbidNonWhitelisted` で 400。データは消えないがエラーになる |
| E-6 | 非常に長い番号（64 文字） | 表示は 1 行 + 中略（T4-1）。DB / API は受理 |
| E-7 | `prisma db push` を先に流してしまった | 列が drop + add され既存値が消える。**Q4=「守るデータあり」なら復旧不可**。T1 手順 1 を飛ばさない |
| E-8 | 共有中の名義の会員番号を変更 | board ペイロードに会員番号が無いので共有先に影響なし（D-4） |
| E-9 | 全桁表示によりスクリーンショットに番号が写る | 撤回により**構造的な対策は無い**。残存リスクとして受容（Q9） |

## 7. 検証ゲート（完了条件）

BE:
```bash
cd apps/api && npx tsc --noEmit
cd apps/api && npm test
cd apps/api && npm run build
```

iOS:
```bash
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/Networking
swift test --package-path meigicho/Packages/DataStore
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```

加えて T4 の手動確認手順 1〜5。

**追加の網羅確認（標準ゲートで落ちない）**:
```bash
grep -rn "member_no_last4\|memberNoLast4\|下4桁\|下四桁" apps/api/src apps/api/prisma meigicho/Packages docs
```
残る想定は `resolve-share` / `update-share-item` の禁止キー検査（`member_no_last4` を残すのは意図的）と、
docs の撤回記録だけ。それ以外がヒットしたら追従漏れ。

## 8. ハンドオフ

1. **先に Q1 / Q4 の回答を取る**（`questions-requirements.md` に書き戻す）
2. T1 を `nest-developer` へ（`.claude/skills/implementing-robustly/SKILL.md` を読ませる。§2 の API 契約を指示文に全文書き写す）
3. T1 完了後、T2（`nest-developer`）と T3（`swift-developer`）を並列委譲
4. T3 完了後、T4 を `swift-developer` へ
5. T5（docs）はいつでも並列
6. **別セッションで** `code-reviewer`。結果は `docs/plans/membership-full-number/review.md`
   - 重点観点: BE-9（書き込み経路 2 本の網羅）/ BE-2（黙殺フォールバック）/ BE-8（DTO の whitelist 検証）/ IOS-2（契約追従漏れ）/ §7 の grep が期待どおりか / **W1〜W11 の docs 更新漏れ（AC-MN-16）**
7. `docs/plans/STATUS.md` の「方針決定（横断）」に
   「2026-08-20 会員番号の暗号化保存・下4桁表示を撤回。共有マスキングは維持」を 1 行追加する
