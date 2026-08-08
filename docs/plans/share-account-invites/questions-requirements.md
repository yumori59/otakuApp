# questions-requirements — share-account-invites

共有を「トークン URL を知っていれば誰でも」から「招待されたアカウントだけ」に変える計画の未決事項。

**書式の約束**:
- `[確定]` — ユーザーが確定済み。再検討しない
- `[提案]` — planner の推奨案と理由。**まだ決定ではない**
- `[Answer]:` — **ユーザーが埋める欄**。埋まるまで `requirements.md` / `plan.md` の該当箇所は「仮（提案どおりで下書き）」扱い

**未回答の Q が 1 つでも残っている間は実装に着手しない**（`.claude/rules/01-aidlc.md`）。

作成日: 2026-08-07 / planner: aidlc-planner

---

## 0. 確定事項（再検討しない）

| # | 確定内容 | 出典 |
|---|---|---|
| F1 | 招待された側は**アプリ内の受信箱**で自分宛ての共有を知る。トークン URL を個別に受け取らなくても、ログインしてアプリを開けば一覧が見える | ユーザー指示 2026-08-07 |
| F2 | 招待されていないアカウントがトークン URL を知っても**中身は一切返さない**。403 で拒否する | ユーザー指示 2026-08-07 |

---

## Q1. 既存の「URL を知っていれば誰でも見られる」トークンリンクを廃止するか（**最重要・他の Q の前提**）

現状 `GET/PATCH /public/shares/:token` は `@Public()` で認証不要
（`apps/api/src/public/public.controller.ts:36,48`）。F2 を満たすには最低限「Bearer 必須 + 招待判定」が要る。

| 案 | 内容 | 影響 |
|---|---|---|
| A | **公開経路を完全廃止**。`/public/shares/:token` は GET/PATCH とも削除 | 一番単純。未ログイン閲覧が不可能になる。iOS `PublicApiClient` / `KeychainSharedBoardTokenStore` / `OpenSharedBoardView` が不要化 |
| B | **既定オフで残す**。`POST /v1/shares` に `visibility: "invited_only" \| "link"` を追加し既定 `invited_only`。`link` を選んだときだけ従来どおり誰でも閲覧可（**read のみ**・write 不可） | アプリ未導入の名義主に見せるケースを残せる。実装量は A + enum 1 個 + 分岐 |
| C | 残すが `410 Gone` を返して段階的廃止 | 移行期間だけの措置。最終的に A |

**`[提案]` B。** 理由: `docs/09-roadmap.md:323` の成長仮説③が「共有リンクがそのまま招待になる＝受け手はアプリの存在と価値を同時に知る」であり、Phase 1 の KPI に「共有リンク経由の新規インストール比率 ≥ 10%」（同 45 行目・472 行目）が入っている。A にすると*アプリ未導入の名義主には何も見せられなくなり*、この KPI が構造的に達成不能になる。B なら既定は招待制（ユーザー要望どおり）で、`link` は明示オプトインの例外に留まる。
**却下した理由（A）**: 単純さでは優るが上記 KPI と正面衝突する。**（C）**: 現時点で実運用データがほぼ無いため段階廃止の必要が薄い。

`[Answer]:` **A（完全廃止）。2026-08-07 ユーザー決定。** KPI試算より「基本的にアカウントを持っている人どうしの機能にしたい」というプロダクト方針を優先。`GET/PATCH /public/shares/:token` はGET/PATCHとも削除する。roadmap KPI「共有リンク経由の新規インストール比率」は本計画のスコープ外として`docs/09-roadmap.md`側で別途扱う（本計画では触れない）。

## Q2. 未ログイン / ゲストの扱い

Q1 = B の場合、`visibility: "link"` の共有は誰が開けるか。

- B-1: 未ログインでも開ける（現状の挙動そのまま）
- B-2: ログインは必須。ただし招待リスト判定はしない（アカウントさえあれば読める）

**`[提案]` B-1。** `link` を選んだ時点でオーナーが公開を了解している。ログインを強制すると Q1-B の目的（アプリ未導入者に見せる）が消える。
※ Q1 = A を選んだ場合、この Q は消滅する。

`[Answer]:` **消滅（Q1=A のため）。** `visibility:"link"` 自体を作らない。

## Q3. 招待の受け入れ / 拒否フロー

- 3-1: **自動**。招待された瞬間から受信箱に出て中身が見える（承諾操作なし）
- 3-2: **承諾必須**。受信箱には「招待が届いています」だけ出て、承諾するまで中身は見えない
- 3-3: 自動で見えるが「非表示にする」（＝自分の受信箱から消す）操作を持つ

**`[提案]` 3-3。** 承諾を必須にすると F1 の「開けば見える」体験が 1 タップ遠くなる。一方、招待は他人が一方的に送れるので受け取り側が消す手段は要る。
**却下（3-2）**: 承諾ステートを持つと `share_recipients.status` の状態遷移が増え、オーナー側 UI にも「未承諾」表示が要る。今回の目的（アクセス制御）には不要。

派生の確認: 非表示にしたことをオーナー側に見せるか。
**`[提案]` 見せない**（受け取り側の心理的負担を作らない）。

`[Answer]:` **3-3（提案どおり）で確定。2026-08-07 ユーザー決定（承諾不要）。** 非表示にしたこともオーナーには見せない（提案どおり）。

## Q4. 招待時にアカウントの実在確認をするか

`ACC-XXXXXX` は `profiles.account_id`（`apps/api/prisma/schema.prisma:70`、サインイン時に `AccountIdGenerator` が発行 — `apps/api/src/auth/auth.service.ts:91`）。存在しない ID を打たれたときの挙動。

- 4-1: **実在確認して弾く**（未知 ID があれば 400）→ 「その ACC-ID が登録済みか」が分かる
- 4-2: **実在確認しない**。未解決の招待として保存し、その ACC-ID を持つユーザーがサインインしたら結び付く
- 4-3: 実在確認するが結果を区別せず「招待しました」と返す（内部で未知 ID を捨てる）

**`[提案]` 4-1。** `ACC-` + 6 桁 hex = 1,677 万通りで、レート制限下の列挙は現実的でない。逆に打ち間違いを黙って飲むと「共有したつもりが誰にも届かない」という最悪の失敗になる（今の UI は自由入力テキスト — `ShareRecipientsView.swift:125`）。
派生の確認: 未知だった ID を**レスポンスに列挙して返すか**（打ち間違い救済のため返したい）。
**`[提案]` 返す**（`details.unknown_account_ids`）+ 招待系ルートに userId 単位のレート制限（30 回/分）。

`[Answer]:` **4-1 + 未知IDをレスポンスに列挙（提案どおり）で確定。2026-08-07 ユーザー承認（一括）。**

## Q5. 招待の追加・削除

現状は `permission` すら発行後に変更できない設計（`ShareRecipientsView.swift:12`「変えたいときは一度停止して作り直す」）。

- 後から招待を追加 / 削除できるか
- 除外したとき、その相手が既に開いている画面をどうするか

**`[提案]`**: 後から追加・削除できるようにする（`POST /v1/shares/:id/recipients` / `DELETE /v1/shares/:id/recipients/:account_id`）。除外は即時有効（次のリクエストから拒否）。**開いている画面を能動的に消しには行かない**（そのためのプッシュ機構が無い）。次の取得・編集で弾かれ、受信箱から消える。
**`permission` の発行後変更は今回もスコープ外**（変えるなら停止して作り直し）。

`[Answer]:` **提案どおり確定。2026-08-07 ユーザー承認（一括）。**

## Q6. 招待人数の上限とプラン（entitlements との整合）

現状 `MAX_SHARED_WITH_ACCOUNT_IDS = 20`（`apps/api/src/shares/dto/create-share.dto.ts:33`）。
entitlements は Free = 有効リンク 1 本（`FREE_SHARE_LIMIT`）/ write 共有の公演数 3 件（`FREE_SHARE_WRITE_EVENT_LIMIT`）。

- 招待人数に Free / Plus の差を付けるか
- 招待された**側**にプラン要件を課すか

**`[提案]` プラン差を付けない。** 1 リンクあたり 20 人まで（既存定数を流用）。招待された側にプラン要件は無い。既存の Free 制限（有効リンク 1 本 / write は公演 3 件）はそのまま維持。
理由: 招待制への移行は「機能追加」ではなく「安全性の修正」なので、ここで新しい課金壁を作ると値上げに見える。課金差別化は既存の 2 軸で足りる。

`[Answer]:` **提案どおり確定（プラン差なし）。2026-08-07 ユーザー承認（一括）。**

## Q7. 受け取り側の board 取得を「トークン」ではなく「共有 ID」で addressing してよいか

F1（受信箱）が入ると、受け取り側はトークン URL を持たないケースが主になる。

**`[提案]`**: `GET /v1/shares/received/:id`（`id` = `share_links.id` UUID）を正の経路にし、トークン URL は
`POST /v1/shares/received/redeem { token }` → `{ share_id }` の変換入口としてのみ残す（ディープリンク互換のため）。
`item_key` / `rev` の HMAC 鍵は従来どおりサーバー内部の `token_hash` を使い続けるので、不透明値の意味論・`share-item-key.ts` は変えない。

`[Answer]:` **提案どおり確定（id addressing採用）。2026-08-07 ユーザー承認（一括）。**

## Q8. 非招待者へのエラーコードを 403 と 404 でどう出し分けるか

F2 は「トークン URL を知っていても 403」。ただし id 経路まで 403 にすると「その共有 ID は存在する」を確定させてしまう。

| 経路 | 非招待者への応答（提案） | 理由 |
|---|---|---|
| `POST /v1/shares/received/redeem`（token） | **403 `SHARE_NOT_INVITED`** | F2 そのもの。呼び出し側は現にトークンを持ち、認証済みで追跡可能。「あなたは招待されていない」と伝えないとユーザーが詰む |
| `GET/PATCH /v1/shares/received/:id`（id） | **404 `SHARE_INVALID`**（未知 id と同一） | id は招待経由でしか知り得ない。非招待者が来ること自体が異常なので存在を confirm しない |

**`[提案]` 上表。** 既存の「未知 / 失効 / 期限切れを区別しない `SHARE_INVALID`」方針（`docs/04-api.md:479`）を崩さずに F2 を満たせる。

`[Answer]:` **提案どおり確定（token=403 / id=404）。2026-08-07 ユーザー決定（「未招待アクセスは403で拒否」の指示に対応）。**

## Q9. 既に発行済みの共有リンクの移行・後方互換

現在の `shared_with_account_ids` は記録用メタ（`docs/10-mock-delta-2026-07-31.md:47`）で、**空配列のまま発行されたリンクが存在しうる**。`invited_only` に切り替えると空配列 = 誰もアクセスできない、になる。

- 9-1: 既存行を全部 `visibility: "link"` で backfill（従来どおり見られるまま。黙って壊さない）
- 9-2: 既存行を `invited_only` にし、`shared_with_account_ids` を招待に昇格（空配列のリンクは実質失効）
- 9-3: 既存行を一律 `revoked_at` で失効させ、作り直させる

**`[提案]` 9-1 + `shared_with_account_ids` の中身は `share_recipients` にも複写。** 本番未リリースで実データはほぼ無い見込みだが、「黙って壊さない」を既定にする。新規発行は既定 `invited_only`。
※ Q1 = A を選んだ場合、9-1 は選べない（9-2 か 9-3 になる）。

`[Answer]:` **9-3（全件失効・リセット）で確定。2026-08-07 ユーザー決定。** 本番未リリースのため既存の`share_links`行は全て`revoked_at`を立てて失効させる。作り直しは新スキーマ（`invited_only`）で行う。

## Q10. 通知

- 10-1: 今回は**アプリ内のみ**（受信箱に未読バッジ）。APNs は `docs/09-roadmap.md` 1-12 の別タスク
- 10-2: 今回 APNs も含める

**`[提案]` 10-1。** `device_tokens` / 送信基盤（roadmap 1-12）が未着手のため、含めると計画が 2 倍になる。未読は `share_recipients.last_viewed_at` とオーナー側の更新時刻の比較でアプリ内バッジのみ出す。

`[Answer]:` **10-1（アプリ内バッジのみ）で確定。2026-08-07 ユーザー承認（一括）。**

## Q11. iOS `PublicApiClient` / `KeychainSharedBoardTokenStore` の去就（契約変更の影響半径）

`PublicApiClient.swift` は「共有リンクを受け取った人は自分のアカウントでログインしていない前提」「公開経路の 401 で自分のアカウントをログアウトさせてはならない（R7 / AC-SB-13-M）」を**設計意図としてコメントで明文化**している。今回の変更でこの前提が反転する。

**`[提案]`（Q1 = B の場合）**:
- 招待経由の board は **`ApiClient`（Bearer + 401 refresh）** を使う。受け取り側は必ずログイン済みなので、従来の懸念（他人の共有を開いただけで自分がログアウトする）は成立しない
- `PublicApiClient` は `visibility:"link"` の**読み取り専用**に縮退（PATCH 経路は削除）
- `KeychainSharedBoardTokenStore` は `link` 共有の履歴保管としてのみ残す。招待経由はサーバー（受信箱）が正なので Keychain に持たない
- **反転した前提はコメントごと書き換える**（読んだ人が古い前提で判断すると IOS-2 相当の事故になる）

**`[提案]`（Q1 = A の場合）**: `PublicApiClient` / `KeychainSharedBoardTokenStore` / `OpenSharedBoardView` / `SharedBoardLink` を削除。

`[Answer]:` **Q1=Aの提案どおり確定（削除）。2026-08-07 ユーザー決定。** `PublicApiClient` / `KeychainSharedBoardTokenStore` / `OpenSharedBoardView` を削除し、招待経由の board は `ApiClient`（Bearer + 401 refresh）に統一する。**（訂正・Q14参照）**: `SharedBoardLink`（token抽出の純粋パーサ）とディープリンク`meigicho://share/<token>`受け口は、redeemエンドポイントの入口として残す（14-a）。

## Q12. オーナー自身が自分の共有を開けるか

**`[提案]`**: `GET/PATCH /v1/shares/received/:id` はオーナー本人も許可する（プレビュー用途）。ただし受信箱一覧（`GET /v1/shares/received`）には**自分が発行したものは出さない**（それは既存の `GET /v1/shares` の役割）。

`[Answer]:` **提案どおり確定。2026-08-07 ユーザー承認（一括）。**

## Q13. `docs/10-mock-delta-2026-07-31.md` の Phase 表の更新

同ドキュメント §3（42〜54 行目）は「Phase 2 で編集権限をメンバーに限定するか、現状モックどおり URL 知っていれば編集可かを**再決定**」と書いており、**今回の変更がまさにその再決定にあたる**。

**`[提案]`**: 本計画の決定後、`docs/10` §3 の Phase 表と §4 の `share_links + shared_with_account_ids -- 記録用。Phase1ではACLに使わない` の記述を更新対象に含める（`plan.md` T-DOC）。

`[Answer]:` **提案どおり確定。2026-08-07 ユーザー承認（一括）。**

---

## Q14. （**Q1=A 確定後に新たに生じた論点**）トークン URL / ディープリンクの入口を iOS から完全に消すか

Q7 / Q8 / Q11 は個別に回答されたが、**Q1=A（公開経路の完全廃止）と組み合わせると整合しない箇所が 1 つ残る**。

- Q7 / Q8 は `POST /v1/shares/received/redeem`（token → share_id）と **403 `SHARE_NOT_INVITED`**（F2）を残すと確定した
- Q11 は `SharedBoardLink`（URL / カスタムスキームから token を取り出す **Domain の純粋パーサ**）を**削除**すると確定した

`SharedBoardLink` を消すと iOS には token を取り出す手段が無くなり、**redeem エンドポイントの呼び出し元が iOS に存在しなくなる**（＝死んだ契約。IOS-1 の逆パターン）。
同時に、`POST /v1/shares` が返す `token` / `url` も**開ける先が無くなる**（`/public/*` は削除され、Web クライアントも存在しない）。
現在オーナー側 UI には「リンクをコピー」ボタンがある（`ShareRecipientsView.swift:186`）。

| 案 | 内容 | 帰結 |
|---|---|---|
| **14-a** | `SharedBoardLink`（純粋パーサ）と `DeepLinkRouter` の `meigicho://share/<token>` 受け口は**残す**。削除するのは Q11 のうち `PublicApiClient` / `KeychainSharedBoardTokenStore` / `OpenSharedBoardView`（URL 貼り付け画面）の 3 つ | オーナーが LINE 等でリンクを送る運用が生き続ける。招待済みなら redeem → board、未招待なら 403（F2 が端から端まで通る）。`token` / `url` はレスポンスに残る |
| **14-b** | Q11 を文字どおり適用し、`SharedBoardLink` も削除。**redeem エンドポイントごと廃止**し、`POST /v1/shares` のレスポンスから `token` / `url` を削除、「リンクをコピー」ボタンも削除 | 共有の伝達手段は「ACC-ID を入力 → 相手の受信箱に出る」の一本のみ。最も純粋。ただし **F2（403）はサーバー内部の防御としてしか意味を持たなくなる**（提示経路が無いので） |

**`[提案]` 14-a。** 理由:
1. F2 はユーザーが最初に挙げた 2 つの確定要件のうちの 1 つで、14-b にすると「トークン URL を知ってしまっても」という前提自体がアプリから消える
2. 「相手の ACC-ID を聞き出す」より「リンクを送る」ほうが実運用の摩擦が小さい。ACC-ID を知らない相手には招待自体を送れない（Q4=4-1 で実在確認必須のため）
3. `SharedBoardLink` は `Foundation` のみに依存する純粋関数でテスト済み（`SharedBoardStoreTests.swift:14-39`）。残しても負債にならない
4. Q11 の趣旨（**未ログインで開ける経路を消す**）は、`PublicApiClient` / `OpenSharedBoardView` / Keychain token store の削除で満たされる

**`plan.md` / `api-contract-delta.md` は 14-a 前提で書いてある。** 14-b を選ぶ場合の差分は `plan.md` §11 に箇条書きで示してあり、修正は局所的。

`[Answer]:` **14-a（提案どおり）で確定。2026-08-07 ユーザー決定。** `SharedBoardLink`（純粋パーサ）と`meigicho://share/<token>`ディープリンク受け口は残す。削除するのは`PublicApiClient`/`KeychainSharedBoardTokenStore`/`OpenSharedBoardView`の3つ（Q11の趣旨どおり「未ログインで開ける経路を消す」を満たす）。

---

## 回答状況

| Q | 状態 |
|---|---|
| Q1 | ✅ **A（完全廃止）** |
| Q2 | ✅ 消滅（Q1=Aのため対象外） |
| Q3 | ✅ 3-3（承諾不要・非表示のみ） |
| Q4 | ✅ 4-1（提案どおり） |
| Q5 | ✅ 提案どおり |
| Q6 | ✅ 提案どおり（プラン差なし） |
| Q7 | ✅ 提案どおり（id addressing） |
| Q8 | ✅ 提案どおり（token=403 / id=404） |
| Q9 | ✅ 9-3（全件失効・リセット） |
| Q10 | ✅ 10-1（アプリ内バッジのみ） |
| Q11 | ✅ Q1=Aの提案どおり（PublicApiClient等を削除） |
| Q12 | ✅ 提案どおり |
| Q13 | ✅ 提案どおり |
| Q14 | ✅ 14-a（ディープリンクの入口は残す） |

**Q1〜Q14 すべて 2026-08-07 にユーザー回答済み。** `requirements.md` / `api-contract-delta.md` / `plan.md` は確定内容に合わせて更新済み。
実装（T1〜T14）は14-a前提で完了している（`docs/plans/STATUS.md` §9参照）。
