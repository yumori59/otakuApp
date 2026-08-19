# application-edit — レビュー記録

実施日: 2026-08-19 / レビュアー: code-reviewer（別セッション）
対象: T1〜T6全差分（初回レビュー）

## 結果サマリ

- 重大: 0件
- 中: 5件（うち4件を修正済み。#5は残課題）
- 軽微/提案: 7件（未対応・残課題として記録）

**マージ可**（重大ゼロ）。

## 中（修正済み）

### #1 nilの日付が「無変更のまま保存」で今日の日付に書き換わる（データ整合性・波及リスク）

`ApplicationEntry.appliedOn`/`resultOn`/`EventEntity.eventDate`はいずれもoptional。編集画面を開くと`?? applicationStore.today`でDatePickerがtodayに初期化され、`ApplicationEditPlanner.makePlan`が「nil != today」を差分と判定して`.set(today)`を組み立ててしまう。ユーザーが何も触っていないのに保存すると日付が書き換わり、公演日の場合は同じ公演を参照する他の申込にも波及する（FR-AE-7）。

**修正**: `ApplicationFormView.swift`の`eventOn`/`appliedOn`/`resultOn`を`Date?`のまま保持する状態管理に変更。DatePickerには表示用フォールバック（today）と書き込み用の実値を分離した計算Bindingを挟み、ユーザーが実際に操作しない限り`@State`はnilのまま維持されるようにした。

### #2 tour/eventが手元に無いとフォームが全項目空で開く

`populateInitialValues`が`tour(for:)`/`event(for:)`のnilを`?? ""`で握り潰していた。保存時に`.notFound`で弾かれるが、ユーザーは全部入力し直した後に失敗を食らう。

**修正**: tour/eventのnilも既存のAC-AE-12（申込自体が見つからない場合）と同じパターンで早期return + `.notFound`扱いにした。

### #3 編集ボタンだけGuestGate（未ログイン誘導）を通っていない

他の書き込み導線は`sheetPresenter.present(_:requiringSignIn:reason:)`経由だが、編集ボタンだけ`sheetPresenter.activeSheet = .editApplication(...)`を直接呼んでいた。

**修正**: `AuthStore`を`ApplicationDetailView`に注入し、`SignInPrompt.editApplication`を追加した上で他画面と同じ`present(...)`経由に揃えた。

### #4 ツアー名だけ変更した場合、他の申込への波及警告が出ない

`editAffectedOtherApplicationsCount`が`eventDraft != nil`のみで判定しており、ツアー名だけの変更（`tourDraft`のみ）では警告が出なかった。しかし`updateScoped`はツアー付け替え時に`event.tourID`を書き換えるため、同じ公演を参照する他の申込も丸ごと移動する。

**修正**: guard条件を`plan.eventDraft != nil || plan.tourDraft != nil`に緩和。

## 中（残課題・未修正）

### #5 ツアー吸収時にアーティスト名の変更が無言で捨てられる

ツアー名を既存の別ツアー名に変更（付け替え）した場合、吸収先の他申込のアーティスト名を保護するため新しいアーティスト名は反映されない（設計として正しい・テスト済み）。しかしUIは編集モードで常に「同じツアーの申込すべてに反映されます。」と表示しており、ツアー名+アーティスト名を同時に変えた場合はアーティスト名が黙って無視されることを伝えていない（BE-2のiOS版）。

対応: 将来「既存のツアー名に変更した場合、アーティスト名は移動先の値が使われます」等の注記を追加する、または吸収検知時にヒントを差し替える。

## 軽微/提案（未対応・残課題）

1. `ApplicationFormView.swift` — `showTourSuggestions`は未使用の`@State`（`AddApplicationView`時代から一度も読まれていない）
2. `editAffectedOtherApplicationsCount`がcomputed propertyのため、body評価のたびに`makePlan`内の`UUIDv7.generate()`が走る。`plan`を一度だけ作って使い回す形が望ましい
3. 変更ゼロで保存しても`applications`のoutboxは無条件で積まれ`updated_at`が動く（既存の`update()`と同じ挙動、回帰ではない）
4. `replaceCompanions`は同行者1人だけ変えても3人分の`updated_at`が動く（既存挙動）
5. ツアー名変更（新規作成側）で元ツアーが0公演の孤児として残り続ける。ツアー表には出ないが、サジェストには出続ける
6. 編集の保存失敗→キャンセルで閉じると`writeError`が残り、詳細画面のErrorBarに表示され続ける。`dismiss()`前の`clearWriteError()`を検討
7. 作成と編集で同行者の重複名義スロットの解決規則が完全一致していない（極端なエッジケース）

## 検証した設計判断（遵守確認済み）

- D-3（1回のcontext.save）: `updateScoped`はtour find-or-create→event upsert/tourID差し替え→application patch→companions全置換を同一`ModelContext`上で行い、saveは1回のみ
- D-5（楽観更新なし）: `ApplicationStore.updateApplication`はrepositoryの戻り値だけを反映し、失敗時は`applications`を書き換えない
- D-4（振る舞い不変の抽出）: `AddApplicationView`削除分と`ApplicationFormView`の`.create`パスを行単位で突き合わせ、差分なしを確認

## 受入基準の状態

AC-AE-02〜06/09/10/13はXCTestで担保・確認済み。AC-AE-01/07/08/11/14/15は手動確認手順（`plan.md`§5）が必要だが、このセッションのシミュレータ制御ツールが入力を配信できず**未実施**。将来のセッションで実機/シミュレータでのタップ操作により実施すること。

## その他の残課題

- T7（R-1: sync pushの同名tour unique違反による巻き添え）は`docs/plans/STATUS.md` §12で別途修正済み（本機能実装中に発見・先行対応）
