# questions-requirements — ios-network-integration

対象: iOS クライアント（`meigicho/`）を NestJS API（`apps/api/`、契約の正 = `docs/plans/backend-domain-modules/api-contract.md`）に接続する。

各項目は **planner 推奨案を `[Assumed]` として暫定確定**し、その前提で `requirements.md` / `contract-mapping.md` / `plan.md` を書いている。
**実装着手前に `[Answer]:` を埋めること。** 推奨案と異なる回答が入った箇所は requirements と contract-mapping を先に更新してから実装する。

**Q3 / Q5 / Q9 はユーザー体験が変わる（機能が減る／画面が変わる）ため、他より優先して回答が要る。**

---

## A. スコープ判断

### Q1. `DataStore`（SwiftData によるローカル永続化）を今回に含めるか

`docs/05-ios-client.md` §1 は 6 モジュール（`Core` / `DesignSystem` / `Domain` / `DataStore` / `Network` / `Features`）を前提とし、
「Phase 0 は **SwiftData が SSoT**。UI は SwiftData だけを読む」と書いている。
一方いまのアプリは SwiftData を一切持たず、`AppDataStore` が `SampleData` をインメモリで持つだけ
（`meigicho/Packages/Domain/Sources/Domain/AppDataStore.swift:11-21`）。`meigicho/project.yml:8-16` の packages にも `DataStore` / `Network` は無い。

`[Assumed]` **今回は `Network` 直結のみ。`DataStore`（SwiftData）は次計画に送る。**

理由:

1. **移行対象のデータが存在しない。** `docs/09-roadmap.md` 1-4「ローカル専用→クラウドへの初回移行」は *Phase 0 を出荷済みでローカルにデータが溜まっている* 前提のタスク。本アプリは未出荷で、端末に守るべき永続データが 1 件も無い（永続化されているのは `theme.seedHex` と `TourShareStore` の擬似共有 JSON だけ）。したがって「SwiftData を先に入れて後でクラウド化する」順序の利得が無い。
2. **同期エンジン抜きの SwiftData は最悪の中間状態になる。** SwiftData を SSoT にした瞬間「ローカルとサーバーどちらが正か」の解決が必要になる。それが `docs/09-roadmap.md` 1-3 の同期エンジン（8 人日・Phase 1 最大の難所）で、しかも **`/v1/sync` は BE 側で意図的にスコープ外**（`backend-domain-modules/questions-requirements.md` Q14）。つまり今 SwiftData を入れても、突き合わせる相手の API が無い。書き込みキューの無い SwiftData は「2 つの真実」を作るだけ。
3. **後から差し込める形にできる。** Repository を `Domain` の protocol にし、実装を `Network` に置く構造にしておけば、`DataStore` は後日 *キャッシュ用デコレータ*（`CachedIdentityRepository(remote:local:)`）として `Features` を一切触らずに挿入できる。今回の構造化そのものが次計画の前提整備になる。

却下案:

| 案 | 却下理由 |
|---|---|
| SwiftData + 同期エンジンを今回まとめて | BE に `/v1/sync` が無い。BE 側の追加計画（LWW・カーソル・push）が先に要り、iOS 単独では完了できない。工数も 8 人日超で本計画（≈6 人日）と別物 |
| SwiftData を「読み取りキャッシュ専用」で今回入れる | 書き込みが無くても「キャッシュが何秒古くてよいか」「起動時どちらを描くか」の判断が必要になり、デコード経路も 2 本になる。上の 3.（後から挿せる）が成り立つ以上、いま払う理由が無い |

Phase 1 のオフライン挙動は **「メモリ内キャッシュ + 明示的なオフライン表示 + 書き込みは不可（理由を明示）」** とする（Q7）。

`[Answer]`:

### Q2. 今回スコープ外にする範囲の確認

`[Assumed]` 以下は本計画のスコープ外。着手前に別計画を立てる。

| 対象 | 出典 | 除外理由 |
|---|---|---|
| SwiftData / オフライン書き込み / 同期エンジン | 05 §5・09 1-3 | Q1。BE に `/v1/sync` が無い |
| ペイウォール UI・StoreKit / RevenueCat | 05 §7・09 1-9/1-10 | 課金は別タスク。本計画は `PLAN_LIMIT_IDENTITY` 403 を**エラー文言で伝えるところまで** |
| AdMob | 09 1-11 | 同上 |
| ローカル通知（`UNUserNotificationCenter`） | 05 §6 | 現状 iOS 未実装。API 接続とは独立。別計画 |
| 統計画面 / `home/summary` / `stats/identities` | 04 §3.5・09 1-5 | BE 側も未実装（Q14 で除外済み）。ホームの 3 指標は従来どおり iOS ローカル集計 |
| Next.js 共有 Web ビュー | 09 1-7 | 本計画は `POST/GET/DELETE /v1/shares` を叩くところまで。`GET /public/shares/:token` の閲覧側は Web の仕事 |
| APNs / `device_tokens` | 09 1-12 | BE 未実装 |
| Google / メール+パスワード認証 | 10 §2「任意」 | BE は Apple のみ実装。iOS 側は**モック UI を撤去**する（Q3） |
| `.xcconfig` による staging/production 切替の完全整備 | 09 1-16 | 今回は `API_BASE_URL` を Info.plist 経由で 1 つ読むところまで |

`[Answer]`:

---

## B. 認証

### Q3. Google / メール+パスワードのログイン UI を撤去してよいか

`AccountView`（`meigicho/Packages/Features/Sources/Features/Account/AccountView.swift:23-81`）には
「ログイン / 新規登録」セグメント・Google ボタン・メール+パスワード欄がある。すべて `AuthStore` のモック
（`AuthStore.swift:33-56`）で、BE には対応するエンドポイントが無く、実装予定も無い（`docs/10` §2 で「任意」、
BE 計画 Q14 で除外）。

`[Assumed]` **撤去する。** ログイン画面は **Sign in with Apple ボタン 1 つ**（+ 利用規約リンク）にする。
`AuthMode` / `signupError` / `emailDraft` / `loginWithGoogle` / `signUpWithEmail` / `generateAccountID` は削除。
`SegmentedPicker` は名義一覧・申込一覧でも使うので **DesignSystem からは消さない**。
`GoogleSignInButton` / `LoginDivider` は本画面専用なら削除（他に参照が無いことを実装時に grep で確認する）。

却下案: 「Google ボタンを残して押したら『準備中』を出す」— 押せるのに動かない UI は IOS-3（配線の無い UI）そのもの。

`[Answer]`: **却下。撤去しない。** Apple を残したまま **Google とメール+パスワードを追加**する
（App Store Guideline 4.8 は Sign in with Apple を提供し続けることで満たす）。
BE 側に実装済み: `POST /v1/auth/google` / `register` / `login` / `password` / `password/reset-request` / `password/reset`
（`docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` §1）。

これに伴う本計画の変更:

- `AuthStore` の `AuthMode` / `emailDraft` / `signupError` は**残す**（実装は BE 接続に差し替え）
- `generateAccountID`（クライアント生成モック）は**やはり削除**する（`account_id` はサーバー発行 — Q3 の元の判断のうちこの 1 点だけは有効）
- `GoogleSignInButton` / `LoginDivider`（DesignSystem）は**削除しない**
- `plan.md` の T1（Apple + Google）/ T1b（メール+パスワード）に分割済み
- Google の `id_token` 取得方法は **Q15** で決める

ユーザー判断の原文（記録）:

> `[Assumed]` を覆す。撤去しない。App Store Guideline 4.8（`docs/08-compliance-risk.md:522`）により、
> Google/メールログインを提供するなら Sign in with Apple の併設が必須。「Apple も併設」した上で
> Google・メール+パスワードも実装する方針。
> **BE 側が現状 Apple のみ実装済み**のため、本タスク着手前に BE へ Google Sign-In 検証・
> メール+パスワード登録/ログインのエンドポイント追加が必要。BE 契約確定まで T1 は着手しない。

**→ この前提条件は解消済み。** BE 拡張は実装・レビュー完了（重大ゼロ）。契約は
`docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` が正。**T1 は着手可能**。

### Q4. Sign in with Apple の nonce の扱い

BE の `AppleTokenVerifier`（`apps/api/src/auth/apple-token.verifier.ts:123-129`）は、
リクエストの `nonce` を **identity token の `nonce` クレームと単純文字列比較**する（サーバー側でハッシュしない）。
一方 iOS で広く使われる作法は「`request.nonce = sha256(raw)` を設定し、サーバーには `raw` を送ってサーバー側でハッシュして比較」。
**この作法をそのまま実装すると必ず 401 になる。**

`[Assumed]` **iOS は `ASAuthorizationAppleIDRequest.nonce` に設定したのと同じ文字列を `POST /v1/auth/apple` の `nonce` に送る**（ハッシュしない）。BE は変更しない。

- 生成: `SecRandomCopyBytes` 32 byte → base64url（`Core` に `Nonce.generate()` を置く）
- 1 回のログイン試行ごとに生成し、レスポンス受領で破棄する

却下案: **BE を「受け取った nonce を sha256 して比較」に変更する**案。ID token が漏れても raw nonce は復元できない、という利点はある。ただし (a) BE の spec・契約・docs/04 の変更が発生し本計画が iOS 単独で閉じなくなる、(b) raw nonce はこのフローでは同一クライアントが両方持つため守れる範囲が限定的、(c) BE は実装・テスト済み。**セキュリティ上ハッシュ方式を採るなら本計画の前に BE 側の差分計画を立てること。**

`[Answer]`:

### Q5. 未ログイン状態でアプリを使えるか（ログインゲートの位置）

現状はログインしなくても全画面が使える（`SampleData` が見えている）。BE 接続後、`/v1/*` はすべて Bearer 必須になるため、
未ログインでは表示するデータが無い。

`[Assumed]` **起動時にログインゲートを置く。** Keychain に有効な refresh token が無ければ、
タブを描かず `SignInView`（**Apple + Google + メール+パスワードの 3 方式** — Q3 の確定に合わせる）を全画面表示する。
ログイン後 `MainTabView` に切り替える。

- `AuthStore.state: .unknown / .signedOut / .signedIn(User)`。`.unknown` の間はスプラッシュ相当のプレースホルダ
- ログアウトは `POST /v1/auth/logout` → Keychain クリア → `.signedOut`
- `SampleData` は **Preview 専用**に降格する（`#Preview` からのみ参照）。実行時には一切出さない

却下案: 「未ログインでもローカルに書けるお試しモード」— ローカル永続化が無い（Q1）ので入力が消える。Q1 で SwiftData を採るなら再検討。

`[Answer]`: **[Assumed]を覆す。全画面ゲートにしない。** ユーザー判断: `docs/08-compliance-risk.md:523`
「サインインを必須にしない: Phase 0 の機能（記録・通知）はアカウントなしで使えること。『アカウント作成を強制するアプリ』は
5.1.1(v) の指摘対象」という既存の法務要件と、当初の Assumed（起動時に全画面ログインゲート）が矛盾していたため。

範囲はユーザー確認により**「閲覧・お試し程度、保存は求めない」**に確定（SwiftDataの追加導入は不要、Q1の判断は維持）:

- 起動時の全画面ログインゲート（`AuthGateView`）は**廃止**。未ログインでも `MainTabView` に入れる
- 未ログイン状態でタブ・画面遷移は自由に見られる。ただし表示データはBEに保存が無いため空/プレースホルダになる
  （**サンプルデータの代用表示はしない** — 「これはお試し用の見本データです」と誤解させない。「ログインするとここに表示されます」等の空状態文言にする）
- 未ログイン状態での**書き込み操作**（名義追加・申込追加・プロフィール編集等）は、操作しようとした時点でログイン画面へ誘導する
  （書き込みが成立しないまま入力させて消える、という却下案の問題を避ける）
- ホーム左上のアカウントアイコン等、既存のログイン導線はそのまま使う
- 影響: T1が実装した`AuthGateView`（全画面ブロック方式）を「ゲスト状態を許すソフトゲート」に変更する追加タスクが必要（T1完了後の差分。T1b/T2/T3のBE接続ロジック自体は変更不要 — 認証済み時の呼び出しは従来どおり）

### Q6. トークンの保管場所と 401 時の挙動

`[Assumed]`

- **refresh token: Keychain**（`kSecClassGenericPassword` / `kSecAttrAccessibleAfterFirstUnlock`）。`Security` フレームワークを直接使う薄いラッパーを `Network/TokenStore.swift` に置く（第三者ライブラリを足さない）
- **access token: メモリのみ**（TTL 3600 秒 = `apps/api/src/auth/auth.service.ts:18`）。プロセス再起動時は refresh で取り直す
- **401 (`UNAUTHENTICATED`) を受けたら 1 回だけ** `POST /v1/auth/refresh` → 元リクエストを再送。**同時に複数リクエストが 401 になっても refresh は 1 回だけ**走るよう actor で直列化する（回転式なので並行 refresh は必ず片方が `AUTH_REFRESH_INVALID` になる）
- refresh が `AUTH_REFRESH_INVALID` 401 を返したら Keychain をクリアして `.signedOut`（サイレントログアウト、アラートは出さない。ログイン画面に戻ることで伝わる）
- **再送は 1 回まで。** 再送後の 401 はそのままエラーにする（無限ループ防止）

`[Answer]`:

---

## C. 既存 UI と契約の非互換

### Q7. ツアー表の「共有中ボード」（その場で状況・座席を編集できる）を廃止してよいか

`ApplicationListView.swift:303-358` の共有テーブルは、共有済みペイロードのコピー上で
`cycleSharedStatus` / `saveSharedSeat` により**状況と座席をその場で編集**できる。`TourShareStore` が UserDefaults に保存する擬似実装
（`TourShareStore.swift:121-141`）。

BE の共有リンクは `permission: "read"` 固定・一方向・閲覧者は Web（`api-contract.md` §8）。
**「共有先が書き換える」機能はサーバーに存在せず、実装予定も無い。**

`[Assumed]` **共有ボードの編集機能は廃止する。** ツアー表は常にローカルデータ（`localTable`）を描き、
共有は「そのツアーのリンクを発行・状態表示・コピー・失効」に置き換える。

置き換え後のツアー行ヘッダ:

| 共有状態 | 表示 | 操作 |
|---|---|---|
| 未共有 | 「未共有」バッジ | 「共有リンクを作成」→ `ShareRecipientsView`（相手 ID 入力）→ `POST /v1/shares` |
| 共有中 | 「共有中」バッジ + `閲覧 N 回 ・ 期限 M/D` | 「リンクをコピー」／「共有を停止」(`DELETE /v1/shares/:id`) |
| 失効/期限切れ | 「共有終了」バッジ | 「もう一度共有する」 |

**注意**: 生トークンは発行時 1 回しか返らない（`api-contract.md` §8「`token` / `token_hash` は含めない」）。
つまり **`GET /v1/shares` からは URL を再構成できない**。よって:

- 発行直後は `url` をメモリに保持して「コピー」を出す
- アプリ再起動後は URL が失われるため、**「リンクをコピー」は出さず「共有中（リンクの再取得はできません）」+「共有を停止して作り直す」** を出す
- これは仕様上の制約であり回避しない（トークン再取得手段の追加は BE 契約変更）

`[Answer]`: **却下。撤去しない。** BE に **共有リンクの write 権限（軽量共同編集）を追加実装済み**
（`api-contract-delta.md` §3・§4）。共有ボードの編集機能は残し、**BE の実 API に接続**する。

確定した設計:

| 項目 | 内容 |
|---|---|
| 発行 | `POST /v1/shares` に `permission: "read" \| "write"`（省略時 `read`）。write は `scope_type: "tour"` のみ |
| write の上限 | **公演数**で制限（free = 3 公演 / plus = 無制限）。超過は `PLAN_LIMIT_SHARE_WRITE` 403。**同時リンク本数の上限（`PLAN_LIMIT_SHARE`）は read/write を区別せず従来どおり** |
| 編集経路 | `PATCH /public/shares/:token/items/:item_key`（**Bearer 不要・token のみ**） |
| 編集できる項目 | **`status` と `seat` だけ**。`round_name` / `note` / 同行者 / 削除は開放しない |
| 競合制御 | `rev`（楽観ロック）。不一致は `CONFLICT` 409 + `details.current` で**その行だけ**再描画 |
| 行単位の可否 | `editable: bool`。`false` の理由（非公開名義 / プラン超過）は**サーバーが区別しない**ので iOS も説明しない |
| オーナー側 | ツアー表は**ローカルデータ一本**。共有ペイロードを取りに行かない。共有中バッジに `閲覧 N 回 ・ 編集 M 回` |
| 受け取り側 | 新規画面 `SharedBoardView`。トークンベースの `SharedBoardRepository` + `PublicApiClient`（`contract-mapping.md` §5.1） |

**C4（生トークンは 1 回だけ）の制約は変わらない**が、write 共有は `item_key` / `rev` で解決するため
「再起動後にリンクをコピーできない」問題は実害が小さくなった（オーナーは自分のデータを直接見るのでボードを開く必要が無い）。
エントリポイントは **Q16** で決める。

ユーザー判断の原文（記録）:

> `[Assumed]` を覆す。廃止しない。BE 側に共同編集機能を追加した上で、共有ボードの状況・座席編集 UI を維持する
> （`docs/10-mock-delta-2026-07-31.md` M9 の想定を前倒し）。
> BE 側に write 権限の共有リンクと、共有先が状況・座席を更新する公開エンドポイントの新設が必要。
> **BE 契約確定まで T4 は着手しない。**

**→ この前提条件は解消済み。** BE 拡張は実装・レビュー完了（重大ゼロ）。契約は
`docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` §3・§4 が正。**T4 / T4b は着手可能**。

### Q8. 会員番号の扱い（契約ズレ E1）

iOS `Membership.memberNo` は平文 String（`Models.swift:6`）。BE は `member_no_last4`（1〜4 文字の英数）のみ受理し、
平文 `member_no` が送られたら 400（`api-contract.md` §4）。

`[Assumed]`

- Domain を `memberNoLast4: String?` に変更する
- `AddMembershipView` の入力欄を **「会員番号の下4桁（任意）」** に変更し、`keyboardType(.asciiCapable)` + 4 文字上限
- **入力された文字列から自動で下 4 桁を切り出す実装にはしない。** 「STL-04821」から `4821` を機械的に切り出すのは推測（末尾がチェックディジットの FC もある）。ユーザーに下 4 桁を明示入力させる
- 既存表示箇所（`IdentityDetailView` の会員情報カード）は「下4桁: 4821」形式に変更
- 平文の全桁保持は Phase 1 では**しない**（`member_no_cipher` は BE 側 Q1 で不採用・鍵管理未決）

`[Answer]`:

### Q9. `Identity.historyVisible` の既定値（契約ズレ E4）

iOS は既定 `true`（`Models.swift:44`）、DB / BE は既定 `false`（`docs/03` §4.4「共有はオプトイン」）。

`[Assumed]` **iOS を `false` に合わせる。** 新規名義は「当落履歴を非公開」で作られ、`SharePreviewView` / `IdentityDetailView` のトグルで
明示的に公開する。IOS-4（仕様にない制約の誤実装）の逆パターンなので、`docs/03` を正とする。

`[Answer]`: **確定（Assumedどおり）**。false に変更する。

---

## D. データ取得戦略

### Q10. 起動時に何をどれだけ取るか

BE のリスト API のページング状況（実装確認済み）:

| エンドポイント | ページング |
|---|---|
| `GET /v1/identities` | 無し（全件） |
| `GET /v1/memberships` | 無し（全件） |
| `GET /v1/tours` | 無し（全件） |
| `GET /v1/events` | 無し（全件） |
| `GET /v1/applications` | **あり**（`limit` 1〜200 既定 50 + `cursor`） |

ホームの 3 指標・名義一覧のソート（更新が近い順 / 当選が多い順）・ツアー表は、いずれも
**全申込を横断した集計**を iOS 側で行っている（`AppDataStore.swift:38-85`）。BE に集計 API が無い（Q2）以上、全件が要る。

`[Assumed]` **ログイン直後と `.refreshable` で 5 本を並行取得し、applications だけ cursor を辿って全件取得する。**

```
async let identities  = GET /v1/identities
async let memberships = GET /v1/memberships
async let tours       = GET /v1/tours
async let events      = GET /v1/events
async let apps        = GET /v1/applications?limit=200 を has_more が false になるまで cursor で反復
```

- **反復の上限は 20 ページ（= 4,000 件）**。超えたら打ち切り、`AppDataStore.truncated = true` を立ててホームに 1 行「表示件数が上限に達しています」を出す。**黙って切り捨てない**
- 個別更新（PATCH/POST）後は**全体再取得をしない**。レスポンスの 1 要素でメモリ上の該当行を差し替える（`api-contract.md` は POST/PATCH とも更新後の要素を返す）
- 失敗時は Q11

`[Answer]`:

### Q11. オフライン / 通信失敗時の UI

既存のエラー表示資産は `FormHint(_:isError:)`（`DesignSystem/.../FormComponents.swift:77-88`）、
`EmptyStateView`、`DS.error` / `DS.errorBG` バッジ（`ApplicationListView.swift:271-273`）の 3 つだけ。新規コンポーネントは最小にする。

`[Assumed]`

| 場面 | 表示 | 根拠 |
|---|---|---|
| 初回ロード失敗（データ 0 件） | 各タブのルートに `EmptyStateView("読み込めませんでした…")` + 「再試行」ボタン | 既存の空状態と同じ場所・同じ型 |
| ロード済みで再取得に失敗 | 画面は**そのまま**。ナビゲーションバー下に 1 行のエラーバー（`DS.errorBG` 背景・`DS.error` 文字・タップで再試行） | `docs/05` §5「モーダルやアラートは絶対に出さない」に従う |
| フォーム保存の失敗 | シートを閉じず、保存ボタン下に `FormHint(message, isError: true)` | `AccountView.swift:64-66` の既存パターン |
| インライン編集（座席・備考・カラー・トグル）の失敗 | 値を**編集前に戻し**、当該行下に `FormHint(isError:)` を 3 秒表示 | 楽観更新をしないので「戻す」は UI の巻き戻しのみ |
| オフライン（`URLError.notConnectedToInternet` 等） | 上記と同じ枠に「オフラインです。接続後に再試行してください」。**書き込み系ボタンは disabled** にしない（押せば理由が出るほうが分かりやすい） | Q1 でオフライン書き込みを持たないため |

新規に作るのは `DesignSystem/Components/ErrorBar.swift`（1 ファイル）だけ。

`[Answer]`:

### Q12. `AppDataStore.today` の扱い

`today` が `SampleData.referenceDate`（2026-07-31 固定、`AppDataStore.swift:15`）。残日数バッジ・「30日以内に更新期限」・
「直近のイベント」がすべてこれを基準にしている。

`[Assumed]` **`Date()` に置き換える。** `AppDataStore(now: @Sendable () -> Date = { Date() })` として注入可能にし、
Preview / テストからは固定値を渡せるようにする（純関数化して検証可能にするため）。
`SampleData.referenceDate` は Preview 用に残す。

`[Answer]`:

---

## E. 検証・ゲート

### Q13. iOS のテストターゲットを新設するか

`CLAUDE.md`「既知の未整備」に「iOS XCTest は…機械ゲートは現状ビルド成功のみ」とある。
一方 `.claude/rules/01-aidlc.md` の iOS 例外は「振る舞いロジックは Domain / Core の純粋関数か BE に寄せる」。
本計画で新規に増える振る舞いロジックのうち、**純関数に切り出せて壊れると実害が大きいもの**は 5 つある。

| 対象 | 置き場所 |
|---|---|
| DTO → Domain マッパー（`identity_summary` 含む全モデル） | `Domain/Mapping/` |
| 日付変換（`YYYY-MM-DD` ⇄ `Date`、ISO8601 ⇄ `Date`） | `Core/APIDateFormat.swift` |
| UUID v7 生成（単調性・バージョン/バリアントビット） | `Core/UUIDv7.swift` |
| エラー envelope → `AppError`（**未知 code を握り潰さない**こと = BE-2 の iOS 版） | `Domain/AppError.swift` |
| リクエスト組み立て（パス・クエリ・ヘッダ） | `Network/Endpoint.swift` の純粋部分 |

`[Assumed]` **`Core` と `Domain` に swift-testing のテストターゲットを新設し、`swift test` を追加ゲートにする。**

- `Packages/Core/Package.swift` / `Packages/Domain/Package.swift` の `platforms` に `.macOS(.v14)` を足し、`.testTarget` を追加
- ゲート: `cd meigicho/Packages/Core && swift test` / `cd meigicho/Packages/Domain && swift test`
- `Network` / `Features` にはテストターゲットを作らない（`URLProtocol` スタブ・SwiftUI 起動のコストが利得を上回る。上表のとおり検証価値のあるロジックは `Core` / `Domain` に寄せる）
- 通ったら `CLAUDE.md` の「検証ゲート」節と「既知の未整備」を更新する

却下案: 「iOS は `xcodebuild build` 成功だけで完了とする」— マッパーは 20 型以上あり、フィールド 1 つの取りこぼしはビルドが通る（IOS-2 そのもの）。ビルドだけでは検出できない。

`[Answer]`:

### Q14. ローカル開発時の接続先と ATS

`[Assumed]`

- `App/Info.plist` に `API_BASE_URL` キーを追加。Debug は `http://localhost:8080`、Release は Cloud Run の URL
- 値は `meigicho/project.yml` の `settings.configs.Debug/Release` から `$(API_BASE_URL)` で流し込む（`.xcconfig` の完全整備は Q2 でスコープ外）
- localhost が http なので **Debug 構成のみ** `NSAppTransportSecurity.NSAllowsLocalNetworking = true` を入れる。`NSAllowsArbitraryLoads` は使わない
- シミュレータからは `make up` の `http://localhost:8080` にそのまま到達する

`[Answer]`:

---

---

## G. BE 拡張（認証・共有 write）に伴う追加の未確定事項

Q3 / Q7 の判断が覆ったことで新たに必要になった判断。**どちらも `[Assumed]` で計画を書いているが、着手前に回答が要る。**

### Q15. Google の `id_token` をどう取得するか（第三者 SDK を追加するか）

BE は Google の OpenID Connect `id_token` を受け取る（`aud` が `GOOGLE_CLIENT_IDS` に含まれること）。
iOS 側の取得方法は 2 択。`requirements.md` NFR-6 は「依存追加ゼロ」を掲げているが、これは Google 認証がスコープ外だった前提で書かれている。

`[Assumed]` **`ASWebAuthenticationSession` + PKCE の自前実装（第三者 SDK を追加しない）。**

理由（詳細は `plan.md` §7.2.1）:

1. 必要なのは**一度きりの `id_token`** だけ。セッション維持は自前 JWT が担うので、SDK の主機能（トークン保管・自動更新・One Tap）が不要
2. `ASWebAuthenticationSession` はシステムフレームワーク（Sign in with Apple で既に `AuthenticationServices` を使う）。RFC 8252 に沿った Google 公認の経路
3. `SWIFT_STRICT_CONCURRENCY: complete` 下で、`GoogleSignIn-iOS` の ObjC 依存 3 つ（AppAuth / GTMAppAuth / GTMSessionFetcher）を `Sendable` に馴らすコストが乗る
4. BE も依存を減らす方針で `jose` を選んでいる（`backend-domain-modules/plan.md` §3.1）。平仄が合う
5. 純関数部分（PKCE・URL 組み立て・コールバック解析）を `swift test` で検証できる

却下案: **`GoogleSignIn-iOS`（SPM）を追加する。** 公式・ブランド準拠・仕様追従は利点だが上記 1〜4 で却下。
ただし自前実装が詰まったら切り替える（`plan.md` R8）。切り替えは NFR-6 の改訂を伴うため **planner に差し戻す**。
影響を `Network/GoogleSignInService.swift` 1 ファイルに閉じる設計にしておく。

**前提条件（回答時に一緒に確認したい）**: Google Cloud で **iOS 種別の OAuth クライアント ID** を作成し、
その値を BE の `GOOGLE_CLIENT_IDS` に設定する必要がある。未設定だと `AUTH_GOOGLE_INVALID` 401 になり iOS 側からは原因が見えない。

`[Answer]`:

### Q16. 共有ボード（受け取り側）のエントリポイント

共有リンクを受け取った人が、どうやってアプリでボードを開くか。

`[Assumed]` **カスタムスキーム `meigicho://share/<token>` + アプリ内の「共有リンクを開く」（URL 貼り付け）の 2 経路まで。**

- Universal Links（`https://share.example.com/s/<token>` のタップでアプリが開く）は `apple-app-site-association` の配信が必要で、
  それは `docs/09-roadmap.md` **1-7（Next.js 共有 Web ビュー・5 人日）** の一部。**本計画のスコープ外**
- 当面、共有先はブラウザで Web ビューを見るか、URL をアプリに貼り付けてボードを開く
- **オーナー自身はボードを開く必要が無い**（自分のデータをネイティブに見ている）。ボードは受け取り側専用

**Universal Links を本計画に含める場合**は BE / インフラ側（AASA 配信・独自ドメイン）の作業が発生するため、
別計画（`docs/plans/share-web-and-universal-links/`）を先に立てる。

`[Answer]`:

### Q17. 受け取った共有トークンの保管場所

`[Assumed]` **Keychain**（`kSecAttrAccessibleAfterFirstUnlock`）に、自分の refresh token とは**別の service 名前空間**で複数本保存する。

- 共有 token は「そのボードを読み書きできる」capability であり、**UserDefaults は不可**（平文で iCloud バックアップに載る）
- 保存するのは `token` と表示用の最小メタ（ツアー名・最終取得時刻）のみ。**ボードの表データはキャッシュしない**（Q1 の「ローカル永続化を持たない」方針と揃える）
- `SHARE_INVALID` 404 を受けたら**その token を破棄**する

`[Answer]`:

---

## F. 既存実装への申し送り（回答不要）

`backend-domain-modules/questions-requirements.md` §E の E1〜E7 に加えて、本調査で見つかった差分。

| # | 内容 | 出典 |
|---|---|---|
| F1 | `Companion` に `id` が無い。BE の `PATCH /v1/applications/:id` は companions **全置換**で、id 単位に更新/新規/削除/復活を判定する（`api-contract.md` §7） | `Models.swift:19-27` — `id: UUID` の追加が必須 |
| F2 | `ApplicationEntry` に `tourID` / `eventID` / `repMembershipID` / `roundName` / `ticketCount` / `priceYen` が無い | `Models.swift:60-73` — 共有スコープ（tour_id）と PATCH に必要 |
| F3 | `ApplicationEntry.eventOn` が非 Optional。BE の `event_date` は nullable | `Models.swift:67` |
| F4 | `Identity.sortOrder` が無い。BE の一覧は `sort_order asc, created_at asc` 順 | `Models.swift:29-37` |
| F5 | ツアーのグルーピングキーが**ツアー名（String）**。BE の共有は tour の UUID スコープ | `AppDataStore.swift:107-135`、`ShareViews.swift:139-145` — `tourID` キーへの移行が必要 |
| F6 | `ThemeStore.seedHex` は UserDefaults のみ。BE は `profiles.theme_color` を持つ | `ThemeStore.swift:14-26` — 端末間で色が揃わない |
| F7 | `AppDataStore.appDisplayName` はメモリのみ。BE は `profiles.app_display_name` | `AppDataStore.swift:8` |
| F8 | Free プランの名義上限 UI がどこにも無い。BE は 4 件目で `PLAN_LIMIT_IDENTITY` 403 | Features 全体を grep して 0 件。Q2 のとおり本計画はエラー文言まで |
| F9 | `Core` に `UUIDv7` が無い（`docs/05` §2.4 にコードだけある）。クライアント発行 UUID は POST 全種で必須 | `Packages/Core/Sources/Core/` に 3 ファイルのみ |
| F10 | `Domain` に Repository protocol が 1 つも無い。`docs/05` §1 の依存図（`Features → Domain ← Network`）が未成立 | `Packages/Domain/Sources/Domain/` |
