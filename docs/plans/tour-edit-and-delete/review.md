# tour-edit-and-delete — Code Review

- レビュー日: 2026-08-21
- 対象ブランチ: `feat/tour-edit-and-delete`（`main` からの working tree 全差分。コミット無し）
- レビュアー: `code-reviewer`（実装セッションとは別セッション）
- 参照: `docs/plans/tour-edit-and-delete/plan.md`（D-1〜D-8 / §2 API 契約 / §4 受入基準）、`requirements.md`、`.claude/rules/feedback_review_patterns.md`

## レビュー結果サマリ

- 重大: 0 件
- 中: 5 件
- 軽微/提案: 6 件

計画（D-1〜D-8）の設計判断はコード上で守られている。BE 製品コードの変更ゼロも確認済み。
重大ゼロだが、**中 5 件のうち #1（Store 側連鎖のキー不一致）と #2（FR-TE-14 文言）は仕様との差**なので、マージ前の修正を推奨する。

### 検証ゲート（レビュアーが独立に再実行）

| コマンド | 結果 |
|---|---|
| `npx jest src/sync/sync.service.spec.ts` | 21 passed |
| `swift test --package-path meigicho/Packages/DataStore` | 63 passed |
| `swift test --package-path meigicho/Packages/Domain` | 284 passed |
| `xcodebuild -scheme Meigicho ... build` | **BUILD SUCCEEDED** |

---

## 重大 (Must Fix)

なし。

以下は「重大ではない」と判断した根拠（依頼された確認観点への回答）:

- **削除連鎖の 1 セーブ（D-5 / C-5）**: `SwiftDataCatalogRepository.swift:91-111` の `deleteTour` は `ModelContext` を 1 つだけ作り、`context.save()` は `:109` の 1 回のみ。ループ内 save なし。`onWrite.didWrite()` は save の後。**N+1 セーブ・IOS-13 型の後付け undo は無い**。
- **identity / membership の非連鎖（AC-TE-09）**: 連鎖は `TourRecord → EventRecord → ApplicationRecord → ApplicationCompanionRecord` のみで、`IdentityRecord` / `MembershipRecord` に触る箇所は無い。`SwiftDataCatalogRepositoryDeleteTourTests.swift:113-132` が明示的に固定している。
- **共通ヘルパ（BE-9）**: `ApplicationCascadeTombstone.apply(to:in:now:)`（`Local/ApplicationCascadeTombstone.swift`）に一本化され、`SwiftDataApplicationRepository.delete`（`:200`）と `SwiftDataCatalogRepository.deleteTour`（`:106`）の**両方**が呼んでいる。重複実装なし。`context.save()` を呼ばない責務分担もコメントで明記されている。
- **同名判定の 3 箇所一致（D-4）**: `SwiftDataCatalogRepository.swift:53-64` の述語は `$0.name == candidateName && $0.id != selfID` で `deletedAt` を見ない。`SwiftDataApplicationRepository.findOrCreateTour`（name のみ）、サーバー `sync.service.ts` の `validateUniqueConstraints`（`{ ownerId, name, id: { not: id } }`・`deletedAt` 無し）と条件が揃っている。論理削除済み同名のケースまで XCTest 済み（`SwiftDataCatalogRepositoryUpdateTourTests.swift:147-178`）。
- **非楽観更新（D-6 / IOS-13）**: `ApplicationStore.swift:451-505`。`updateTour` / `deleteTour` とも `await` 成功後にのみ配列を触り、`catch` では配列に一切触れず `writeError` のみ設定。「戻す」処理は存在しない。`ApplicationStoreNetworkTests.swift` の `testUpdateTourFailure...` / `testDeleteTourFailure...` が固定。
- **本番書き込み経路（D-3）**: `AppEnvironment.swift:130` が `SwiftDataCatalogRepository` を注入。`RemoteCatalogRepository.deleteTour`（`:53-63`）は「本番の書き込み経路としては使われない」と doc コメント付き。BE の `PATCH`/`DELETE /v1/tours/:id` は変更もされていない。
- **`ShareLinkStore.revoke` 非呼び出し（D-7）**: `ApplicationListView.swift` の削除経路に `revoke` の呼び出しは無い。
- **BE 製品コード変更ゼロ（T7）**: `git diff` の `apps/api` 配下は `src/sync/sync.service.spec.ts` のみ（+148 行）。
- **IOS-5**: `TourFormView.swift` は `SwiftUI / DesignSystem / Domain` のみ import。`Features` から `DataStore` / `Networking` への参照は増えていない。

---

## 中 (Should Fix)

### 1. `ApplicationStore` の連鎖除去・件数算出が `eventID` 経由で、`groupApplications` の `tourID` とキーが違う

`meigicho/Packages/Domain/Sources/Domain/Stores/ApplicationStore.swift:513-524`

```swift
public func tourDeletionImpact(tourID: UUID) -> (eventCount: Int, applicationCount: Int) {
    let eventIDs = Set(events.filter { $0.tourID == tourID }.map(\.id))
    let applicationCount = applications.filter { eventIDs.contains($0.eventID) }.count
    ...
}
private func removeTourCascade(_ tourID: UUID) {
    let eventIDs = Set(events.filter { $0.tourID == tourID }.map(\.id))
    applications.removeAll { eventIDs.contains($0.eventID) }
    ...
}
```

一方 `groupApplications`（`:309-320`）は `app.tourID` でグループを作る。`ApplicationEntry` は `tourID` を**持っている**（`Models.swift:144`）のに、削除側だけ `events` 配列を経由している。

`ApplicationStore` は「手元に event が無い申込」を**設計として許容している**（`fillMissingEvents:107-118` / `ensureEvent:122-129` / `display(for:)` の「公演情報を読み込み中」）。その状態でツアーを削除すると:

- `removeTourCascade` がその申込を `applications` から除去できず、**リストモード / ホームの件数 / 名義詳細の申込履歴に残り続ける**（FR-TE-12・AC-TE-11 に反する）。ツアー表からは `groupApplications` が `tour(for:) == nil` で捨てるので消え、「表からは消えたのにリストには居る」という一番わかりにくい形になる
- `tourDeletionImpact` の申込件数が実数より少なく出る（FR-TE-10 の「実データから埋め込む」に反する）

本番構成（SwiftData 直読み・`listEvents()` は全件返す）では発生確率は低いが、`RemoteCatalogRepository` 経路や pull 途中の状態では起こりうる。

**修正案**: 判定を `tourID` 主・`eventID` 従にする。1 行で済む。

```swift
let eventIDs = Set(events.filter { $0.tourID == tourID }.map(\.id))
applications.removeAll { $0.tourID == tourID || eventIDs.contains($0.eventID) }
```

`tourDeletionImpact` の `applicationCount` も同じ述語に揃える。併せて `ApplicationStoreNetworkTests` に「event が `store.events` に無い申込もツアー削除で消える」ケースを追加すること。

### 2. 共有中ツアーの警告文が FR-TE-14 の趣旨を伝えていない

`meigicho/Packages/Features/Sources/Features/Applications/ApplicationListView.swift:456-464`

```swift
message += "\n共有中です。削除しても共有相手には解除の通知は届きません。"
```

FR-TE-14 / plan D-7 が要求しているのは「**共有中の相手はこのツアー表を開けなくなります**」。実装の文言は「通知が届かない」ことしか言っておらず、**削除するとサーバー側で `SHARE_INVALID` になり相手が開けなくなる**（`resolve-share.use-case.ts`）という肝心の帰結が抜けている。ユーザーは「共有はそのまま生き続ける」と誤読しうる。

**修正案**: `"\n共有中です。削除すると共有相手はこのツアー表を開けなくなります。"` に置き換える（通知の有無を足すなら後段に）。

### 3. `AC-TE-17` の jest テストが、コメントで主張している性質を検出できない

`apps/api/src/sync/sync.service.spec.ts:664-700`

コメントは「同一バッチで tombstone 化済みでも … FK 検証は `deletedAt` を見ない」と書いているが、

- モックの返り値は `deletedAt: null`。**削除済み親のケースを一度もセットアップしていない**
- `tx.tour.findUnique` 等は `mockResolvedValue(...)` なので **`where` 句を無視して常に同じ値を返す**。`validateForeignKeys` に `deletedAt: null` フィルタを追加する改悪をしても、このテストは通り続ける

つまり回帰ガードとして機能していない（BE-10 の「$transaction モックが改悪を検出できない」と同型の弱さ）。

**修正案**: `mockImplementation` に変えて where 句を検査する。

```ts
tx.tour.findUnique.mockImplementation(async (args: { where: Record<string, unknown> }) => {
  if ('deletedAt' in args.where) return null; // FK 検証が deletedAt で絞ったら落ちる
  return { ownerId: USER_ID, updatedAt: new Date('2026-07-31T09:00:00.000Z'), deletedAt: new Date('2026-08-01T00:00:00.000Z') };
});
```

親の `deletedAt` を**非 null** にすることで「削除済み親を参照する子の tombstone が通る」という AC の文言そのものを再現できる。`tx.event.findUnique` / `tx.application.findUnique` も同様。

（AC-TE-18 の方は `tx.tour.findFirst.mockImplementation` で `where.name` を検査し、`tx.tour.upsert` の呼び出し回数と引数まで見ているので**有効なガードになっている**。）

### 4. 削除ボタンが destructive として描かれておらず、既存の削除導線と平仄が取れていない

`ApplicationListView.swift:414-417`

```swift
TourActionButton(isDeleting ? "削除中…" : "削除", icon: "trash") { showDeleteConfirmation = true }
```

`TourActionButton`（`DesignSystem/Components/FormComponents.swift:302-329`）は `theme.primary` 固定で、`role` も色も他のボタンと同じ。結果として「共有相手を選んで共有する」「編集」「削除」が**同じ見た目で横並び**になる。

既存の削除導線は `ApplicationDetailView.deleteButton()`（`:255-268`）が `Button(role: .destructive)` + `foregroundStyle(DS.error)`。ツアー削除は申込削除より影響が大きい（配下の公演・申込・同行者を全部消す）のに、視覚的な警告が申込削除より弱いのは逆転している。

**修正案**: `DS.error` を使う destructive バリアント（`TourActionButton` に `role`/`tint` を足すか、専用の小ボタンを `ApplicationListView` 内に置く）にする。

### 5. 計画産物がブランチにコミットされていない

`docs/plans/tour-edit-and-delete/`（`plan.md` / `requirements.md` / `questions-requirements.md`）は**メインリポジトリのワーキングツリーに未追跡で存在するだけ**で、`feat/tour-edit-and-delete` の worktree には**ファイル自体が無い**（`git ls-files` も空）。

`.claude/rules/01-aidlc.md`「計画産物は `docs/plans/<feature>/` に置き、**リポジトリにコミットする**」に反する。今回の差分は `docs/05-ios-client.md` / `docs/09-roadmap.md` / `api-contract.md` から `docs/plans/tour-edit-and-delete/` を参照しているため、**このままコミットすると本文からリンク切れの参照が生まれる**。

**修正案**: 3 ファイル（+ 本 review.md）を本ブランチに含めてコミットする。

---

## 軽微 / 提案 (Nice to Have)

1. **docs の API 記述が実装と不一致**: `docs/05-ios-client.md`（S4拡張の表）と `docs/09-roadmap.md`（0-11c）が `TourFormView(mode: .edit)` と書いているが、実装は `TourFormView(tourID: UUID)` で `mode` を持たない（`Forms/TourFormView.swift:12-13`・`SheetContentView.swift:40`）。`ApplicationFormView(mode:)` からの類推で書いたと思われる。`TourFormView(tourID:)` に直す。
2. **docs のタイポ**: `docs/05-ios-client.md`「それぞれ outbox へ enqueue し（… の4コレクション経由）**で**同期する」— 助詞が重複している。
3. **同名チェックのコメントが「サーバーと同じ条件」と言い切っている**: `SwiftDataCatalogRepository.swift:55-56`。サーバー側は `{ ownerId: userId, name, id: { not: id } }` で **`ownerId` も条件に含む**のに対し、ローカルは name のみ。plan R-3 が「ローカル DB は 1 ユーザー分しか持たない前提をコメントに残す」と指示していたのでその一文を足すとよい。
4. **event だけ先に tombstone された状態では配下 application が取り残される**: `deleteTour` は `EventRecord.fetchActive(tourID:)`（`deletedAt == nil`）を辿るため、pull で event の tombstone だけ先に届いた状態でツアーを削除すると、その event 配下の未削除 application が連鎖対象から漏れる。`ApplicationRecord` に `tourID` が無い（`ApplicationRecord.swift:11`）ので構造上やむを得ないが、`deleteTour` の doc コメントに前提として書き残すと将来の誤読を防げる。
5. **`TourFormView.populateInitialValues` が `applicationStore.writeError = nil` を打つ**（`:80`）。共有プロパティなので、背後のツアー表に出ていたエラーバー（`ApplicationListView.swift:206-208`）も一緒に消える。`ApplicationFormView.populateInitialValues`（`:180-200`）は writeError をクリアしない。挙動としては妥当だが平仄は崩れているので、どちらかに揃えるか意図をコメントに残す。
6. **削除ボタンだけサインインゲートが無い**: 編集は `sheetPresenter.present(.editTour(id:), requiringSignIn: auth, reason:)`（`:407-413`）を通すのに、削除は `showDeleteConfirmation = true` を直に立てる（`:414`）。FR-TE-19 のとおりゲスト時はツアー表自体が出ない（`ApplicationListView.swift:88-96`）ので実害は無いが、非対称は将来の変更で穴になりうる。

---

## 残課題（レビュー対象外だが完了前に必要）

- **手動確認が未実施**。plan §5 の手順のうち **AC-TE-01 / 04（UI 表示）/ 13 / 14 / 15 / 16 / 19** はコードレビューでは担保できない。特に:
  - AC-TE-13: 確認ダイアログの件数が実データで正しく出るか（中 #1 を直すなら再確認が必要）
  - AC-TE-14: 機内モードでの編集・削除 → 復帰後にサーバー側へ反映されるか（tours → events → applications → companions の依存順 push が 1 バッチで通るか）
  - AC-TE-15: 削除後に pending notification requests から当落通知が消えるか
  - AC-TE-16: 削除したツアー名で新規申込 → find-or-create で復活し、過去の申込は戻らないこと
- 実 DB を使った同期の統合テストは未整備（`CLAUDE.md` の既知の未整備どおり）。AC-TE-17 / 18 は Prisma モック上の検証にとどまる。

---

## 良かった点

- **BE-9 対策が計画どおりに実装されている**。`ApplicationCascadeTombstone` へ切り出し、既存の `SwiftDataApplicationRepository.delete` を**新実装側に合わせて書き換えた**（コピペで 2 本目を作らなかった）。`context.save()` を呼ばない責務境界もコメントで明示。
- **`deleteTour` が 1 セーブで閉じている**。plan D-5 却下 c（Store が件数分ループして N+1 セーブ）を回避できている。
- **D-4 の「`deletedAt` で絞らない」が、条件だけでなく XCTest まで揃っている**。`testUpdateTourRenameToExistingSoftDeletedNameThrowsConflict` は R-2 の非自明な仕様を明文化した良いテスト。
- **FR-TE-7（同値保存）の判定が `TourRecord.apply(patch:)` と同一の解決ロジック（`applied(to:) ?? ""`）を使っている**ので、「判定は差分なしなのに適用すると値が変わる」というズレが構造的に起きない。
- **件数算出を View ではなく Store に置き**（`tourDeletionImpact`）、XCTest で固定している（`testTourDeletionImpactCountsEventsAndApplicationsUnderTour`）。
- **AC-TE-18 の jest テストが `tx.tour.upsert` の呼び出し回数・引数まで検証**しており、BE-11 の「事前チェックで例外を起こさない」設計を本当に固定している。
- `RemoteCatalogRepository.deleteTour` に「本番未使用」と理由（D-3）を書き残しており、IOS-1（未配線のデッドコード）と混同されない形になっている。
- 差分全体で `Features → DataStore/Networking` の逆流なし（IOS-5）、`Domain` への SwiftData 持ち込みなし、`op: "delete"` のような契約外の値の新設なし（BE-2）、payload キーの追加・改名なし（C-4）。
