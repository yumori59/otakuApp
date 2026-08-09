# bugfix-batch1 レビュー（`work/bugfix-batch1`）

対象: `git diff main...work/bugfix-batch1`
コミット: 47eab25(Bug3) / 8db67ff(Bug4) / 88e6a28(Bug2) + 本レビューでの修正コミット
レビュー日: 2026-08-10 / スコープ外: Bug1（対応済み）・中低優先度バグ

## サマリ

- 重大: 2 件（いずれも本レビュー内で修正・再検証済み → **残 0**）
- 中: 2 件（うち 1 件は本レビューで修正）
- 軽微/提案: 3 件

## 重大 (Must Fix) — 修正済み

### C-1 `ApiClient.store(_:epoch:)` の「打ち消し clear」が、新しく採用したセッションの refresh token を消す

`ApiClient.swift:219-230`（修正前）。世代ズレを検知したときに無条件で
`accessToken = nil` / `await tokenStore.clear()` を実行していた。
`await tokenStore.write` 中に `adoptSession`（サインイン・パスワード変更後の再採用）が
割り込んだ場合、打ち消しの `clear()` が**新しいセッションの refresh token**まで消す。
結果、サインインした直後に Keychain が空になり、次の refresh で
`runRefresh` → `tokenStore.read() == nil` → `endSession()` でサイレントログアウトする。

ログアウト競合（元の中-2）を直した結果、その鏡像であるサインイン競合を新たに作っていた。
実測で再現を確認（打ち消し実装だと Keychain が `nil`、期待は `refresh-new`）。

**修正**: 打ち消しをやめ、Keychain への変更（write / clear）を
`applyToken(_:)` で **actor 上で決めた順序どおりに直列化**した（`ApiClient.swift:236-252`）。
「最後に決めた操作が最後に反映される」ので、
- ログアウト割り込み → 古い write の後に clear が走り最終状態は空
- サインイン割り込み → 古い write の後に新しい write が走り最終状態は新しい token

`store` は書き込み後の世代確認を「採用できたか」の判定にだけ使う（副作用なし）。
`clearSession` / `endSession` も `applyToken(nil)` を通す。

回帰テスト追加: `ApiClientRefreshTests.swift` `testWriteRaceWithAdoptKeepsNewSession`
（修正前の実装に対して Red を確認済み）。既存の
`testWriteRaceWithLogoutEndsWithClearedToken` も Green のまま。

### C-2 削除シートを「閉じる」た後に、遅れて完了した Apple 再認可がアカウント削除を続行する

`AccountDeleteView.swift:103`（修正前）。「閉じる」の無効化条件を `auth.isBusy` に緩めた結果、
`isReauthorizing` 中でもシートを閉じられるようになったが、`submit()` の Task は
`Task { await submit() }` で作られており **dismiss では止まらない**。

- Apple のシステムシートが出ない / 応答しない → ユーザーが「閉じる」を押す
- 60 秒後に新設のタイムアウトが `.failed` で resume
- `submit()` の続きが走り、`.failed` は「ベストエフォートで続行」なので
  **`auth.deleteAccount` が実行され、画面が無い状態でアカウントが削除される**

不可逆な破壊操作がユーザーの中断意思の後に走るため重大と判定。

**修正**: `AppleReauthorizationCoordinator.cancel()`（`resume(.cancelled)` に集約）を追加し、
「閉じる」で必ず呼ぶ（`AccountDeleteView.swift:103-110` / `AppleReauthorization.swift:66-73`）。
`submit()` は `.cancelled` を「削除中止」として `return` するので、削除は走らない。
併せて 60 秒待たずに即座に処理が終わる。

## 中 (Should Fix)

### M-1 `unread` の契約変更がドキュメントに反映されていなかった（修正済み）

`docs/plans/share-account-invites/api-contract-delta.md:298` は
`unread = last_viewed_at IS NULL OR last_viewed_at < share_links.updated_at` のまま。
実装は `last_edited_at` 基準に変わっており、この機能の契約 SSOT が実装とズレる。
本レビューで同ファイルを更新し、変更理由（BE-7）と既知の制約を追記した。

### M-2 タイムアウトの `.failed` は「削除続行」に倒れる

`AppleReauthorization.swift:26,58-62`。60 秒タイムアウトは `.failed` を返し、
`AccountDeleteView.submit()` は `.failed` を「ベストエフォートで続行」として扱う
（`plan.md` §5.3 の方針どおり）。C-2 の修正で「閉じた後に削除される」経路は塞いだが、
シートを開いたまま 60 秒放置した場合は **Apple トークン失効なしで削除が実行される**。
仕様上は許容されるが、`.failed` の理由をユーザーに見せる余地はある（今回は仕様変更になるため未対応）。

## 軽微 (Nice to Have)

### N-1 自分の編集で自分が未読になる

`received-share.presenter.ts:59-63`。write 権限の招待者が自分でボードを編集すると
`last_edited_at > 自分の last_viewed_at` になり、自分の受信箱で `unread: true` になる。
`updated_at` 基準の旧実装でも同じだったので回帰ではないが、
将来的には「誰が編集したか」を持たない限り解消できない構造。

### N-2 オーナーの実データ更新は `unread` に出ない

申込・名義の更新は `share_links` 行を触らないため `last_edited_at` は進まない。
`updated_at` 基準でも同じだった（既知の制約として契約に追記済み）。

### N-3 `InboxRow` の `updatedAt` が未使用になった

`received-share.presenter.ts` からの参照が消えた。select から落とすかはコストに見合わないので現状維持でよい。

### N-4 読み取りは直列化キューを通らない（C-1 修正の残余）

`ApiClient.currentRefreshToken()` / `runRefresh` 冒頭の `tokenStore.read()` は
`applyToken` のキューを通らないため、書き込み保留中に古い値を読む可能性が残る。
refresh は `refreshTask` で 1 本に集約されており実害の経路が見当たらないため今回は据え置く。

## 良かった点

- Bug2 のテストが `DelayedWriteTokenStore` で **Keychain 書き込みの中断点**そのものを狙って
  再現している（ネットワーク遅延に頼らない）。旧実装に対する Red も本レビューで再確認した
- Bug3 の resume 経路が `resume(_:)` 1 箇所に集約されており、
  タイムアウトと delegate の二重 resume が `@MainActor` + `guard let continuation` で構造的に閉じている。
  `timeoutTask` のキャンセル漏れも無い
- Bug4 が `computeUnread` として純関数に切り出され、4 分岐がコメントと 1:1 で対応している。
  再発防止テスト（他の招待者の閲覧で unread が戻らない / オーナー編集後は戻る）が
  BE-7 の症状そのものを検証している
- 3 つの修正はファイル・レイヤともに独立しており、相互作用は無い

## 検証

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン |
| `cd apps/api && npm test` | 887 passed / 87 suites |
| `cd apps/api && npm run build` | 成功 |
| `cd meigicho/Packages/Networking && swift test` | 167 passed |
| `xcodebuild ... build` | BUILD SUCCEEDED |

### 手動確認（機械ゲート外）

1. Apple ログインのアカウントで削除シート →「アカウントを削除する」→ Apple シートで**キャンセル** →
   削除されず、シートが閉じられること
2. 同上で Apple シート表示中に（機内モード等で応答が遅い状態にして）「閉じる」→
   その後アカウントが削除されていないこと（C-2）
3. サインアウト直後にサインインし直して、アプリを再起動してもログイン状態が保たれること（C-1）
4. 招待者 2 人で共有を開き、A が開いても B の受信箱の既読が戻らないこと（Bug4）
