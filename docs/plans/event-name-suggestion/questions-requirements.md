# event-name-suggestion — 要件確認

ユーザー要望（原文）:
> ツアーの公演名が過去のやつを選択し、即入力できるようにしたい

各問に**仮回答**を置いた（`input-history-suggestions/questions-requirements.md` と同じ運用）。
**Q1・Q4 は実装着手前にユーザー確認が必要**（挙動が目に見えて変わる／スコープが増える）。
Q2・Q3・Q5 は既存実装と docs から機械的に決まるので仮回答のまま確定してよい。

確定したら本ファイルの `[Answer]:` を「（仮）」→「（確定・日付）」に書き換えること。

---

## 前提の訂正（重要・2026-08-26 実測）

本計画の起票時点で「`docs/plans/input-history-suggestions/` は未実装（docs だけ存在）」という前提が
共有されていたが、**誤り**。実測結果:

| 確認 | 結果 |
|---|---|
| `git log --oneline -8` | `c1658d1 Merge pull request #19 from yumori59/feat/input-history-suggestions` が **main の HEAD** |
| `InputSuggestion.swift` | `meigicho/Packages/Domain/Sources/Domain/Models/InputSuggestion.swift` に**存在**（`candidates(from:)` / `match(_:query:limit:)` / `maxSuggestions = 5`） |
| `FormSuggestionList` | `DesignSystem/Sources/DesignSystem/Components/FormComponents.swift:96-123` に**存在**（`minHeight: 44`） |
| 4 フィールドの配線 | ツアー名 `ApplicationFormView.swift:69`・アーティスト `:78`・会場 `:87`・FC名 `MembershipFormView.swift:73` すべて**配線済み** |
| `tour-edit-and-delete` / `membership-full-number` | PR #17 / #18 として**マージ済み** |

→ 起票時の論点「2 つの計画の実装順序」は**消滅**した。本計画は
`input-history-suggestions`（roadmap 0-11d）の**素直な後続**として、共有部品を再利用するだけでよい。
`ApplicationStore.swift` / `ApplicationFormView.swift` を触る他の未実装計画も現時点で無い。

---

## Q1. 公演名候補の絞り込み範囲

公演名は実データ上「ツアー名 + 都市」の形（プレースホルダも `例）STELLARIS ARENA TOUR 2026 -福岡公演-`、
`ApplicationFormView.swift:58`）。他 3 フィールドと違い**共通接頭辞が長い**。

- A: **全履歴から絞り込まない**（会場名 = FR-4 / D-5 と同じ扱い）。ただし並び順を「公演日の新しい順」にする
- B: ツアー名欄が非空ならそのツアーの公演に絞り、空なら全履歴（二段規則）
- C: ツアーで絞る（ツアー名未入力なら候補ゼロ）

`[Answer]: A（確定・2026-08-26・ユーザー承認）`

理由:

1. **入力順序**。フォームは 公演名 →ツアー名 の順（`ApplicationFormView.swift:57,65`）。公演名を打つ時点で
   ツアー名欄は空であることが支配的で、B / C の絞り込み条件がそもそも成立しない
2. **主用途と相性が悪い**。最頻の用途は「同じ公演に別名義でもう 1 件申し込む」で、このとき新規フォームの
   ツアー名は空。C だと候補ゼロ、B だと結局 A に落ちる
3. **同一ツアー内の他公演は再利用価値が低い**。同じツアーの次の公演は別都市（＝別文字列）。会場名で
   絞り込みを却下した理由（D-5）と同じ構図が成り立つ
4. ただし A をそのまま採ると**辞書順 + 上限 5 件**で「STELLARIS ARENA TOUR **2025** -◯◯公演-」が
   5 枠を占有し、最新ツアーの候補が 1 件も出ない事故が起きる（`InputSuggestion.candidates(from:)` は
   `sorted()` 昇順・`InputSuggestion.swift:15`、`match` は先頭 `prefix(limit)`・`:26`）。
   → **公演名だけ「公演日の新しい順」で候補を作る**ことを A の条件とする（`requirements.md` FR-ES-4）

---

## Q2. 公演名候補を選ぶと「同じ公演（同じ `event_id`）」に紐づくのか

- A: **紐づかない。テキスト入力の補助のみ**（推奨）
- B: 同じ公演エンティティを再利用する（find-or-create by name）

`[Answer]: A（確定・2026-08-26）`

根拠（実測）:

- 作成経路の `EventDraft` は既定引数で毎回新規 UUID を発行する（`Drafts.swift:77`）
- ローカルの `upsertEvent` は `draft.id` でしか既存を探さない（`SwiftDataApplicationRepository.swift:271`）。
  ツアーのような名前ベースの find-or-create は**公演には無い**（`findOrCreateTour:219-268` と対比）
- BE も同じ。`CreateApplicationUseCase` は `events.upsertForApplication` を id で呼ぶ
  （`apps/api/src/applications/use-cases/create-application.use-case.ts:41-42`）

B を選ぶと iOS ローカル + BE + 同期の 3 面を変えることになり、本要望（入力の手間削減）に対して
スコープが跳ね上がる。

**副作用として書き残すこと**: 現状、同じ公演名で 2 件申し込んでも `event_id` が別なので
`docs/01` R2-8 の重複申込検知（`DuplicateApplicationDetection.duplicateEventIDs` は `eventID` 基準・
`DuplicateApplicationDetection.swift:5-11`）は**発火しない**。これは本計画以前からの既存挙動であり
本計画では直さない。サジェスト導入で「同じ公演にまとまる」と誤解させないよう、UI 文言でも
「同じ公演になります」とは書かない。

---

## Q3. マッチ規則・上限・表示条件は既存 4 フィールドと同じでよいか

- A: 同じ（部分一致 / 大小無視 / 完全一致は除外 / 1 文字以上で表示 / 上限 5 件 / 空なら非表示）
- B: 公演名だけ変える

`[Answer]: A（確定・2026-08-26）` — `InputSuggestion.match` をそのまま使う。規則を 5 フィールド目で割らない（NFR-1）。
Q1 で変えるのは**候補ソース側の並び順**だけで、マッチ規則は共有のまま。

---

## Q4. 公演名候補をタップしたとき、他の欄も自動補完するか

ツアー名候補タップ時にアーティスト名を補完する前例がある（FR-6 / D-3・`ApplicationFormView.swift:69-74`）。

- A: しない（公演名だけ埋める）
- B: **空の欄だけ**、その公演から ツアー名 / アーティスト名 / 会場 を補完する（公演日は補完しない）
- C: 空でなくても上書きする

`[Answer]: B（確定・2026-08-26・ユーザー承認）` — **本計画で最も確認価値が高い項目**。

理由:

- 主用途「同じ公演に別名義でもう 1 件」で、公演名だけ埋めても残り 3 欄を手で打つことになり、
  要望の「即入力」に届かない
- 「空の欄だけ」ならユーザーの入力を消さない（D-3 の設計思想と同じ）。かつ編集モードでは
  各欄が初期値で埋まっているため**実質何も起きない** → FR-AE-7/8 の波及セマンティクスに
  触れずに済む（モード分岐を書かずに安全側へ倒せる）
- 公演日を対象外にするのは、作成モードでは `populateInitialValues` が必ず `today` を入れる
  （`ApplicationFormView.swift:174-178`）ので「空の欄だけ」規則では触れず、規則を素直に保てるため。
  過去公演の日付を引き継ぎたいかはユーザーの意図に依存し、黙って書き換えるべきではない
- 副次的な利点: ツアー名が空のまま保存されると `trimmedTourName` が**公演名をツアー名として使う**
  （`ApplicationFormView.swift:267-270`）ため、公演ごとに別ツアーが増える。B はこれを自然に防ぐ
- 却下 C: 編集モードで会場・アーティストを黙って書き換え、FR-AE-7/8 経由で**他の申込にも波及**する
- 却下 A: 実装は最小だが要望の体感価値が小さい

**A を選んだ場合**: `requirements.md` の FR-ES-5 / AC-ES-04-T / AC-ES-08-M を削り、
plan.md の T2 を「`existingEventNames` のみ追加」に縮める（他タスクは不変）。

---

## Q5. ロードマップ上の位置づけ

`docs/09-roadmap.md:85` に 0-11d（input-history-suggestions・0.5人日）がある。3-3
（`docs/09:163` 公演情報マスタ・全ユーザー横断・Phase 3）とは別物（本件は自分の履歴のみ・BE 変更ゼロ）。

`[Answer]: 0-11e として 0.5 人日で追記（確定・2026-08-26）`
