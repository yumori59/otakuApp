# requirements — share-account-invites（共有のアカウント招待制化）

**状態: 確定**（`questions-requirements.md` Q1〜Q13 回答済み・2026-08-07）。
残る未確定は **Q14 のみ**（トークン URL の入口を iOS に残すか。本書は **14-a = 残す** 前提で記述）。

作成日: 2026-08-07 / 更新: 2026-08-07（Q1=A 確定を反映）/ planner: aidlc-planner
関連: `docs/plans/backend-domain-modules/`（shares / public 初版）・`docs/plans/backend-auth-and-shares-extension/`（write 権限）・`docs/plans/ios-network-integration/`（T4 / T4b）

---

## 1. 背景と、この計画が答えている問い

`docs/10-mock-delta-2026-07-31.md` §3「共有モデルの整理」は、モックに 2 層が混在していると指摘したうえで段階を切っている:

| Phase | 仕様（同ドキュメント 51〜54 行目） |
|---|---|
| Phase 1 | トークン付き**読み取り専用**。`shared_with_account_ids` はメタ表示のみ |
| Phase 2 | 共同編集。**編集権限をメンバーに限定するか、現状モックどおり「URL 知っていれば編集可」かを再決定** |

**本計画はこの「Phase 2 の再決定」そのものである。**
決定（2026-08-07・ユーザー）は **「メンバー（＝招待されたアカウント）に限定する。公開トークン経路は完全に廃止する」**。

実際には Phase 1 の途中で write 権限（`docs/plans/backend-auth-and-shares-extension/`）が先に入ってしまい、
現在は **「URL を知っていれば誰でも他人のデータを書き換えられる」** 状態になっている。
`docs/09-roadmap.md:519` のリスク L3（共有リンクの URL が第三者に渡り他人の情報が漏れる）に対する緩和策が
「128bit ランダム・30 日期限・失効操作・noindex」のみで、**認可が存在しない**のが現状の実装である。

### 1.1 現状の一次確認（コードで裏取り済み）

| 事実 | 根拠 |
|---|---|
| `GET /public/shares/:token` は認証不要 | `apps/api/src/public/public.controller.ts:36-45`（`@Public()`） |
| `PATCH /public/shares/:token/items/:item_key` も認証不要 | 同 `:48-59` |
| 認可判定は「トークンが有効か」だけ。呼び出し元アカウントを一切見ていない | `apps/api/src/public/use-cases/resolve-share.use-case.ts:41-51` / `update-share-item.use-case.ts:56-66` |
| `shared_with_account_ids` は `String[]` として保存されるだけで、どの判定にも使われていない | `apps/api/prisma/schema.prisma:239`、`shares.service.ts:58` に書き込みのみ。`resolve-share` / `update-share-item` に参照なし |
| iOS も「アクセス制限ではなく記録用」と UI で明言している | `meigicho/.../Share/ShareRecipientsView.swift:133` |
| iOS 受け取り側は Bearer を持たない設計（意図的） | `meigicho/.../Network/PublicApiClient.swift`（冒頭コメント）・`RemoteSharedBoardRepository.swift:7` |
| `ACC-XXXXXX` はサインイン時に必ず発行され、`profiles.account_id` は unique | `apps/api/prisma/schema.prisma:70` / `auth/account-id.generator.ts` / `auth.service.ts:91,139,178` |
| `item_key` / `rev` の HMAC 鍵は `token_hash` | `apps/api/src/public/share-item-key.ts`（`resolve-share.use-case.ts:102` の `tokenHash` 受け渡し） |
| `/v1` を外すルートは `app.setup.ts` の定数で管理されている | `apps/api/src/app.setup.ts:7-12`（`GLOBAL_PREFIX_EXCLUDE`） |
| 独立 Web ビューは既に廃止済み。閲覧の正はアプリ内 SharedBoard | `docs/plans/STATUS.md`（2026-08-05 決定）/ `docs/09-roadmap.md:101` |

### 1.2 ギャップ分析

- **ある**: 共有リンクの発行・一覧・失効（BE + iOS）、read/write 権限、公開ペイロードのマスキング、楽観ロック（`rev`）、iOS の board UI・編集 UI・競合解決 UI
- **ない**: 招待の実体（ACL）、受信箱（受け取り側の一覧）、招待の追加・削除 API、受け取り側の認証経路、`share_recipients` 相当のテーブル
- **死んでいない**: 実装済み分は全て配線済み（`AppRoute.sharedBoard(token:)` / `DeepLinkRouter` / `AppEnvironment` / `HomeView.swift:97` に到達経路あり）。したがって**既存 UI は改修・削除対象であって、作り直しではない**

### 1.3 Q1=A（公開経路の完全廃止）が意味すること

`/public/shares/:token` の **GET / PATCH をルートごと削除する**。ただし:

- **`apps/api/src/public/` のファイルを全部消すのではない。** このディレクトリには公開コントローラのほかに、
  ペイロード組み立てとマスキングの中核（`public-share.presenter.ts` / `identity-summary.service.ts` /
  `shared-applications.service.ts` / `share-item-key.ts` / `share-write.ts`）が入っている。
  **これらは新しい認証経路がそのまま使う**。消してよいのは `public.controller.ts` / `public.module.ts` と `@Public()` の付いたルートだけ
- 残る資産は `apps/api/src/shares/board/` へ**移設**する（`public` という名前が実態と合わなくなるため）
- `GLOBAL_PREFIX_EXCLUDE` から 2 つのパスを外す。**外し忘れると `/v1/public/shares/:token` という別経路が生える**

---

## 2. 機能要件

### FR-1 招待（オーナー側）

| ID | 要件 |
|---|---|
| FR-1-1 | 共有リンク発行時に招待先アカウント（`ACC-XXXXXX`）を **1〜20 件必須**で指定する。0 件では発行できない |
| FR-1-2 | 招待先はサーバーが実在確認する。未知の ACC-ID が含まれていたら共有は作られず 400 を返し、**どの ID が未知だったかを返す**（Q4=4-1） |
| FR-1-3 | 発行後に招待を追加できる（Q5） |
| FR-1-4 | 発行後に招待を削除できる。削除は即時有効で、以後その相手のリクエストは拒否される（Q5） |
| FR-1-5 | オーナーは自分の共有の招待一覧（ACC-ID / 表示名 / 最終閲覧時刻）を見られる |
| FR-1-6 | `permission`（read / write）は従来どおり**発行後変更不可**。変えるなら停止して作り直す（スコープ外） |

### FR-2 アクセス制御

| ID | 要件 |
|---|---|
| FR-2-1 | 共有は、**認証済みかつ招待リストに含まれるアカウント**だけが閲覧できる。例外は無い（Q1=A により「誰でも見られる共有」という状態が存在しない） |
| FR-2-2 | 招待されていないアカウントがトークンを提示したら **403 `SHARE_NOT_INVITED`**（F2 / Q8） |
| FR-2-3 | 招待されていないアカウントが共有 ID を提示したら **404 `SHARE_INVALID`**（未知 ID と区別しない・Q8） |
| FR-2-4 | 未認証（Bearer 無し）でどの共有経路に触っても 401。**中身は一切返さない** |
| FR-2-5 | 書き込み（PATCH）も同じ招待判定を通す。既存の `permission=="write"` / `editable` / `rev` の判定は変えない |
| FR-2-6 | オーナー本人は招待に含まれていなくても自分の共有を開ける（Q12） |
| FR-2-7 | **`/public/shares/:token` の GET / PATCH は存在しない**（ルートごと削除。到達したら 404） |

### FR-3 受信箱（受け取り側・F1）

| ID | 要件 |
|---|---|
| FR-3-1 | ログインしてアプリを開けば、自分宛ての共有一覧が見える。トークン URL は不要 |
| FR-3-2 | 一覧の各行に：スコープ名（ツアー名）・オーナーの表示名 / ACC-ID・権限（閲覧のみ / 編集可）・期限・未読 |
| FR-3-3 | 承諾操作は不要。招待された時点で見える（Q3=3-3） |
| FR-3-4 | 受け取り側は各行を「非表示」にできる。非表示はオーナーには見せない（Q3=3-3） |
| FR-3-5 | 自分が発行した共有は受信箱に出さない（Q12） |
| FR-3-6 | 失効・期限切れになった共有は受信箱から消える |
| FR-3-7 | 未読は**アプリ内バッジのみ**。プッシュ通知はスコープ外（Q10=10-1） |

### FR-4 トークン URL の扱い（**Q14-a 前提**）

| ID | 要件 |
|---|---|
| FR-4-1 | ディープリンク `meigicho://share/<token>` は引き続き受け取れる。**URL 貼り付け画面（`OpenSharedBoardView`）は削除する**（未ログインで開ける入口を残さないため・Q11） |
| FR-4-2 | 招待済みユーザーがトークンを提示した場合、`redeem` で共有 ID に変換して board へ遷移する（Q7） |
| FR-4-3 | 未ログインでディープリンクを開いた場合はサインインを促し、**サインイン後に保留していたトークンで再試行する** |
| FR-4-4 | 招待されていないユーザーがディープリンクを開いた場合、403 を受けて「この共有はあなたに共有されていません」だけを表示する（F2） |

### FR-5 既存データの移行（Q9=9-3）

| ID | 要件 |
|---|---|
| FR-5-1 | 既存の `share_links` は**全件 `revoked_at` を立てて失効させる**。backfill はしない |
| FR-5-2 | 失効させた共有は受信箱にも出ない。オーナー側の一覧には失効済みとして残る（既存 `GET /v1/shares` は失効済みも返す仕様） |
| FR-5-3 | 共有を続けたいオーナーは**新スキーマで作り直す**（招待先の ACC-ID 指定が必須になる） |
| FR-5-4 | `share_links.shared_with_account_ids` カラムは**削除する**。記録用メタという概念自体が無くなるため（Q1=A / Q13） |

---

## 3. 非機能要件

| ID | 要件 |
|---|---|
| NFR-1 | 非招待者に対して、共有の**存在・オーナー・スコープ名・件数のいずれも**推測させない（既存 `SHARE_INVALID` の方針を継承 — `docs/04-api.md:479`）。唯一の例外が `redeem` の 403（トークン所持者にのみ返る） |
| NFR-2 | 招待 API は ACC-ID の列挙に使えてはならない。userId 単位のレート制限（30 回/分）を掛ける |
| NFR-3 | 受信箱一覧は N+1 を作らない。`share_recipients.user_id` にインデックスを張り、1 クエリ + tour 名の一括解決で組む（既存 `SharesService.tourNames` と同じ手法） |
| NFR-4 | ログに ACC-ID / トークン / 座席文字列を出さない（既存 `update-share-item.use-case.ts:102` の方針を継承） |
| NFR-5 | レイヤ規約 Controller → UseCase → Service → Prisma を守る（ADR-009 / BE-3） |
| NFR-6 | iOS: `Domain` は `Foundation` のみ import。`Features` は `Network` / `DataStore` を直接参照しない（IOS-5） |
| NFR-7 | **マスキング規則を再実装しない。** 既存 `public-share.presenter.ts` を移設して再利用する（同じレスポンスを組み立てる箇所を 2 つに増やさない） |
| NFR-8 | 削除する iOS シンボルの参照元を全て潰す。特に**広告禁止画面リスト**（`AdSlotForbiddenScreensTests.swift:20` / `AdGatekeeperTests.swift:146` が `OpenSharedBoardView.swift` を名指ししている）を更新すること |

---

## 4. 制約・スコープ外

| 項目 | 扱い |
|---|---|
| APNs / プッシュ通知 | **スコープ外**（roadmap 1-12・Q10） |
| `permission` の後から変更 | **スコープ外**（FR-1-6） |
| Universal Links | **スコープ外**（`docs/plans/ios-network-integration/plan.md` §7.7 のまま） |
| 招待人数のプラン差別化 | **付けない**（Q6） |
| グループ / チームという概念 | 作らない。招待は共有リンク単位（tour 単位）に閉じる |
| Web クライアント | 存在しない（`docs/plans/STATUS.md` 2026-08-05 決定）。Q1=A により今後も作らない |
| 招待メール送信 | **スコープ外**。伝達手段はアプリ内受信箱 + ディープリンク |
| `docs/09` KPI「共有リンク経由の新規インストール比率 ≥ 10%」 | **本計画では扱わない**。Q1=A の決定でこの導線は失われるため、KPI の再設定は `docs/09-roadmap.md` 側で別途起票する（ユーザー指示） |

---

## 5. 受入基準（AC）

BE の AC は `*.spec.ts` に翻訳する（Red 先行）。iOS のみの AC は `-M` 接尾辞を付け手動確認手順とする。

### 5.1 招待の作成・管理

| AC-ID | 基準 |
|---|---|
| AC-SI-01 | `POST /v1/shares` で `shared_with_account_ids` が未指定 / 空配列 → 400 `VALIDATION_ERROR` |
| AC-SI-02 | 存在しない ACC-ID を含む → 400 `SHARE_RECIPIENT_UNKNOWN`、`details.unknown_account_ids` に該当 ID のみ。**共有は作られない**（部分成功しない） |
| AC-SI-03 | 成功時、`share_recipients` に招待件数分の行が作られ、`user_id` が解決済みで入る |
| AC-SI-04 | 同じ ACC-ID を重複指定 → 重複排除して 1 行だけ作る（400 にしない） |
| AC-SI-05 | 小文字 `acc-3f9a21` は 400（既存 `ACCOUNT_ID_RE` の大文字 hex 規約を変えない — BE-2） |
| AC-SI-06 | 自分自身の ACC-ID を招待 → 400 `SHARE_RECIPIENT_SELF` |
| AC-SI-07 | 招待は 1 リンクあたり 20 件まで。21 件目は 400 |
| AC-SI-08 | `POST /v1/shares/:id/recipients` で招待を追加でき、既存の招待は消えない。既に招待済みの ACC-ID は冪等（`invited_at` を更新しない） |
| AC-SI-09 | `DELETE /v1/shares/:id/recipients/:account_id` で 204。存在しない ACC-ID でも 204（冪等） |
| AC-SI-10 | 他人の share `:id` に対する招待の追加 / 削除は 404 `NOT_FOUND`（BE-4） |
| AC-SI-11 | 失効済み / 期限切れの share `:id` への招待追加は 404 `NOT_FOUND` |
| AC-SI-12 | 最後の 1 人を削除しても 204（実質誰も開けなくなるが、意図的な操作としてありうる） |
| AC-SI-13 | 判定順序が契約どおり（DTO → self → 実在確認 → `PLAN_LIMIT_SHARE` → `PLAN_LIMIT_SHARE_WRITE` → 作成）。Free で上限超過かつ未知 ID 混在なら **`SHARE_RECIPIENT_UNKNOWN` が先に返る** |

### 5.2 アクセス制御

| AC-ID | 基準 |
|---|---|
| AC-SI-20 | 招待済みユーザーの `GET /v1/shares/received/:id` は 200 で、マスキング仕様が従来と同一のペイロードを返す |
| AC-SI-21 | 招待されていないユーザーの `GET /v1/shares/received/:id` は **404 `SHARE_INVALID`**。message にスコープ・オーナーを含めない |
| AC-SI-22 | Bearer 無しの `GET /v1/shares/received/:id` は 401 |
| AC-SI-23 | オーナー本人は招待に無くても `GET /v1/shares/received/:id` 200（FR-2-6） |
| AC-SI-24 | 失効 / 期限切れ / 未知 id は全て 404 `SHARE_INVALID`（区別しない） |
| AC-SI-25 | `POST /v1/shares/received/redeem` に有効トークン + 招待済み → 200 `{ share_id }` |
| AC-SI-26 | 同上 + **招待されていない** → **403 `SHARE_NOT_INVITED`**（F2） |
| AC-SI-27 | 同上 + 未知 / 失効 / 期限切れトークン → 404 `SHARE_INVALID`（3 者を区別しない） |
| AC-SI-28 | 招待を削除された直後の `GET` / `PATCH` は 404 |
| AC-SI-29 | `PATCH /v1/shares/received/:id/items/:item_key` の判定順序が契約どおり。**招待判定は `permission` 判定より前**（read リンクに非招待者が来たら 403 ではなく 404） |
| AC-SI-30 | `GET /public/shares/:token` は**ルートが存在しない**（404） |
| AC-SI-31 | `PATCH /public/shares/:token/items/:item_key` も**ルートが存在しない**（404） |
| AC-SI-32 | `GET /v1/public/shares/:token` も 404（`GLOBAL_PREFIX_EXCLUDE` から外した結果、別経路が生えていないこと） |

### 5.3 受信箱

| AC-ID | 基準 |
|---|---|
| AC-SI-40 | `GET /v1/shares/received` は自分が招待されている有効な共有だけを返す |
| AC-SI-41 | 失効 / 期限切れの共有は返さない |
| AC-SI-42 | 自分が発行した共有は返さない（FR-3-5） |
| AC-SI-43 | 非表示にした共有は返さない。`POST /v1/shares/received/:id/hide` → 204、`DELETE` で取り消し |
| AC-SI-44 | 各行に `share_id` / `scope_type` / `scope_name` / `permission` / `owner.account_id` / `owner.display_name` / `invited_at` / `expires_at` / `unread` が入る |
| AC-SI-45 | `token` / `token_hash` / `scope_id` / 内部 UUID / 他の招待者の ACC-ID / 会員番号を**含まない**（BE-4） |
| AC-SI-46 | 招待 0 件のとき `{ items: [] }`（404 にしない） |
| AC-SI-47 | `GET /v1/shares/received/:id` に成功したら `share_recipients.last_viewed_at` が更新され、次回の `unread` が false になる |

### 5.4 移行（Q9=9-3）

| AC-ID | 基準 |
|---|---|
| AC-SI-60 | 移行処理の実行後、既存の `share_links` は全件 `revoked_at IS NOT NULL` になる |
| AC-SI-61 | 移行後、既存トークンでの `redeem` は 404 `SHARE_INVALID`（失効として扱われる） |
| AC-SI-62 | 移行は冪等（2 回実行しても既に立っている `revoked_at` を上書きしない） |

### 5.5 iOS（手動確認）

| AC-ID | 基準 |
|---|---|
| AC-SI-70-M | 受信箱画面に、自分宛ての共有が一覧表示される。1 タップで到達できる導線がある（IOS-1 / IOS-3） |
| AC-SI-71-M | 受信箱の行をタップすると board が開く。read なら編集 UI が出ない / write なら状況・座席を編集できる |
| AC-SI-72-M | 招待されていない共有のディープリンクを開くと「この共有はあなたに共有されていません」と表示され、内容は一切出ない（F2） |
| AC-SI-73-M | 未ログインでディープリンクを開くとサインイン導線が出て、サインイン後に自動で board へ進む（FR-4-3） |
| AC-SI-74-M | オーナー側の共有作成画面が「記録用」ではなく「ここに入れたアカウントだけが見られます」になっており、ACC-ID 未入力では発行できない |
| AC-SI-75-M | オーナー側で招待の追加・削除ができ、削除した相手の受信箱から消える（2 アカウントで確認） |
| AC-SI-76-M | 共有ボードを開いても自分のアカウントがログアウトされない（`ApiClient` へ移行しても IOS-6 / R7 の事故が起きない） |
| AC-SI-77-M | 削除した `OpenSharedBoardView` への導線（`HomeView.swift:97`）が残っていない。ホームから死んだシートが開かない |

---

## 6. エッジケース

| # | ケース | 期待 |
|---|---|---|
| E-1 | 招待先ユーザーがアカウント削除した | `share_recipients.user_id` の FK cascade で招待行が消える。`docs/plans/account-deletion/` の削除フローに `share_recipients` を含める |
| E-2 | オーナーがアカウント削除した | 既存どおり `share_links` が cascade で消え、招待も消える。受信箱から消える |
| E-3 | 招待中に共有が失効した | 受信箱から消える。開いていた画面は次の操作で 404 |
| E-4 | 招待を消した直後に相手が PATCH を送った | 404 `SHARE_INVALID`（403 と区別しない） |
| E-5 | 招待先が `ACC-` 形式だが未登録 | AC-SI-02 で 400 |
| E-6 | 同じユーザーが複数の共有に招待されている | 受信箱に複数行。並びは `share_recipients.created_at` desc |
| E-7 | オーナーが自分を招待 | AC-SI-06 で 400 |
| E-8 | 受信箱を開いた時点で共有が期限切れ寸前 | 一覧取得時の `now` で判定。開いた瞬間に切れていれば board 側で 404 |
| E-9 | オフライン | 受信箱は**キャッシュしない**（board 内容と同じ扱い。既存 `SharedBoardStore` の方針）。`LoadState.failed` |
| E-10 | 同一 ACC-ID が別ユーザーに再割り当てされる | 招待は `user_id` 解決済みで持つので旧 user に紐づいたまま。`account_id` はスナップショット（表示用） |
| E-11 | 招待の重複 POST | 冪等。`@@unique([shareLinkId, accountId])` |
| E-12 | タイムゾーン | 既存どおり全て UTC timestamptz。表示は端末ローカル |
| E-13 | 招待済みだが `permission="read"` の board に PATCH | 403 `FORBIDDEN`（招待判定を通ったあとの権限判定） |
| E-14 | 移行前に発行されたトークンでディープリンクを開く | 失効しているので 404 `SHARE_INVALID` →「この共有は終了しています」（AC-SI-61） |
| E-15 | 招待 20 件のリンクにさらに 1 件追加 | 400（合計で 20 を超えられない） |

---

## 7. 影響範囲（層チェックリスト）

### 7.1 DB（`apps/api/prisma/schema.prisma`）

- `ShareRecipient` モデル新設（`share_recipients`）
- `ShareLink.sharedWithAccountIds` を**削除**（FR-5-4）
- `ShareLink` に `recipients ShareRecipient[]` リレーション
- `User` に `shareRecipients ShareRecipient[]` リレーション
- **`visibility` カラムは作らない**（Q1=A により「公開共有」という状態が存在しないため）
- 移行: 既存 `share_links` 全件に `revoked_at` を立てる（Q9=9-3）

### 7.2 BE（`apps/api/src/`）

| ファイル | 変更 |
|---|---|
| `public/public.controller.ts` | **削除** |
| `public/public.module.ts` | **削除** |
| `public/public-share.presenter.ts` ほか 5 ファイル | `shares/board/` へ**移設**（中身はほぼそのまま。NFR-7） |
| `app.setup.ts` | `GLOBAL_PREFIX_EXCLUDE` から `public/shares/*` の 2 行を削除 |
| `app.module.ts` | `PublicModule` を外し、`ShareBoardModule` / `SharesReceivedModule` を登録（**直列必須ファイル**） |
| `common/errors/error-codes.ts` | `SHARE_NOT_INVITED` / `SHARE_RECIPIENT_UNKNOWN` / `SHARE_RECIPIENT_SELF` |
| `shares/dto/create-share.dto.ts` | `shared_with_account_ids` を必須化（1〜20 件） |
| `shares/dto/update-share-recipients.dto.ts` | **新規** |
| `shares/share-recipients.service.ts` | **新規**（実在確認・作成・追加・削除・招待判定） |
| `shares/shares.service.ts` | `sharedWithAccountIds` の書き込み削除 |
| `shares/shares.presenter.ts` | `recipients` を返す。`shared_with_account_ids` は廃止 |
| `shares/shares.controller.ts` | recipients 2 ルート追加 |
| `shares/use-cases/create-share.use-case.ts` | 実在確認 → 招待作成の TX |
| `shares/use-cases/add-recipients.use-case.ts` / `remove-recipient.use-case.ts` | **新規** |
| `shares/received/**` | **新規**（inbox / board / redeem / hide / patch item） |
| `shares/board/use-cases/resolve-share.use-case.ts` | token 起点 → shareLink 起点。招待判定を追加 |
| `shares/board/use-cases/update-share-item.use-case.ts` | 同上 |
| `common/throttling/throttle-route.decorators.ts` | `ThrottleShareWrite` のカウント単位を token → userId + share_id |

### 7.3 iOS（`meigicho/`）

| ファイル | 変更 |
|---|---|
| `Network/PublicApiClient.swift` | **削除**（Q11） |
| `Network/SharedBoardTokenStore.swift` | **削除**（Q11） |
| `Features/SharedBoard/OpenSharedBoardView.swift` | **削除**（Q11） |
| `Features/Home/HomeView.swift:97` | `OpenSharedBoardView` のシート提示を削除（IOS-1） |
| `DesignSystem/Tests/.../AdSlotForbiddenScreensTests.swift:20` / `Domain/Tests/.../AdGatekeeperTests.swift:146` | 削除画面の名指しを除去（NFR-8。**放置するとテストが落ちる**） |
| `Domain/SharedBoardStore.swift` | `SavedSharedBoard` / `SharedBoardTokenStoring` を削除。`SharedBoardLink`（純粋パーサ）は**残す**（Q14-a）。Store を shareID 起点へ |
| `Domain/Tests/.../SharedBoardStoreTests.swift` | token store 関連テストを削除、`SharedBoardLink` のテストは残す |
| `Domain/Repositories/Repositories.swift:91` | `SharedBoardRepository` のコメント（「`PublicApiClient` のみを使う」）を書き換え |
| `Domain/Models/*` | `ShareRecipient` / `SharedInboxItem` 追加 |
| `Domain/AppError.swift` | `.shareNotInvited` / `.shareRecipientUnknown(accountIDs:)` |
| `Domain/ShareLinkStore.swift` | 招待の追加・削除 |
| `Domain/SharedInboxStore.swift` | **新規** |
| `Network/Endpoint.swift` / `ApiClient.swift` | `publicPath` / `isVersioned` の扱い（`/health` 以外の利用者が消える）を整理 |
| `Network/Remote/RemoteSharedBoardRepository.swift` | `ApiClient` 経由・shareID 起点へ |
| `Network/Remote/RemoteSharedInboxRepository.swift` | **新規** |
| `Network/Remote/RemoteShareRepository.swift` | recipients 2 メソッド + `SHARE_RECIPIENT_UNKNOWN` の details 格上げ |
| `Network/DTO/ShareDTO.swift` / `SharedBoardDTO.swift` | `recipients` / inbox / redeem |
| `Features/SharedInbox/**` | **新規** |
| `Features/SharedBoard/SharedBoardView.swift` | shareID 起点・未招待表示 |
| `Features/Share/ShareRecipientsView.swift` | 招待必須化・`:133` の「記録用」文言削除・招待の追加削除 UI |
| `Features/Navigation/AppRoute.swift` | `.sharedInbox` / `.sharedBoard(shareID:)` |
| `App/AppEnvironment.swift` | `publicApiClient` / `sharedBoardTokenStore` を削除、inbox repository を注入（**直列必須ファイル**） |
| `App/DeepLinkRouter.swift` | redeem + 未ログイン保留トークン |

### 7.4 docs

| ファイル | 変更 |
|---|---|
| `docs/04-api.md` §3.7 | 契約の反映（正は `api-contract-delta.md`） |
| `docs/03-database.md` §4.9 | `share_recipients` / `shared_with_account_ids` 削除 |
| `docs/05-ios-client.md` | 受信箱画面追加・`PublicApiClient` 削除の反映 |
| `docs/10-mock-delta-2026-07-31.md` §3 / §4 | **Phase 2 の再決定結果を書き込む**（Q13・本計画の必須成果物） |
| `docs/09-roadmap.md` | L3 の緩和策に招待制を追記。KPI「共有リンク経由の新規比率」の再検討を残課題として記載 |
| `docs/plans/STATUS.md` | 本計画のセクション更新 |
