# application-edit — Requirements

作成済みの申込（公演情報・代表者・同行者・当落・座席・メモ）を後から編集できるようにする。

- 前提となる論点と暫定回答: `questions-requirements.md`（Q1=C / Q2=B / Q3=A / Q4=Tour更新 / Q5=削除は対象外 / Q6=出さない / Q7=置く / Q8=統合）
- 未回答のまま計画を進めているため、**回答が上記と異なった場合は本ファイルと `plan.md` を先に直す**

## 1. 用語の確定

| 要望の語 | 実体 | 根拠 |
|---|---|---|
| 「ツアーの内容」 | Application（申込）1 件 + その `event` + `tour` | `schema.prisma:149-233` |
| 「同行者」 | `ApplicationCompanion`（申込に紐づく。Tour には存在しない） | `schema.prisma:214` / `docs/01-product-overview.md:266-270` |

## 2. 機能要件

| ID | 要件 |
|---|---|
| FR-AE-1 | 申込詳細画面（`ApplicationDetailView`）から編集画面を開ける。導線はナビゲーションバー右上の「編集」 |
| FR-AE-2 | 編集できる項目は追加フォームと同じ 12 項目: 公演名 / ツアー名 / アーティスト / 会場 / 公演日 / 代表者 / 同行者×3 / 申込日 / 当落発表日 / ステータス / 座席 / メモ |
| FR-AE-3 | 編集画面の初期値は現在の値。公演名・会場・公演日・ツアー名・アーティストは `event` / `tour` から解決する |
| FR-AE-4 | 同行者の制約は作成時と同一: 最大 3 人 / 同一名義の重複不可 / 代表者と同じ名義は選べない / 名義未登録は氏名テキストで登録。`position` は 0 起点連番に振り直す |
| FR-AE-5 | **既存同行者の `id` を保持する**。表示名や名義だけ変えた場合に別レコードを作らない。行を消した場合のみソフトデリート |
| FR-AE-6 | 保存時は**変更されたフィールドだけ**を送る。`companions` は差分があるときだけ全置換で送る（無変更なら送らない） |
| FR-AE-7 | 公演名 / 会場 / 公演日の変更は当該 `event` を更新する。同じ `event` を参照する他の申込が存在する場合、保存前に「他 N 件にも反映されます」を提示する（Q3-A） |
| FR-AE-8 | アーティスト名の変更は当該 `tour` を更新する。UI に「同じツアーの申込すべてに反映されます」を注記する |
| FR-AE-9 | ツアー名の変更は**付け替え**（入力名で find-or-create し、この `event` の `tour_id` を差し替える）。既存 Tour のリネームは行わない（Q2-B） |
| FR-AE-10 | オフラインでも編集・保存できる。ローカル（SwiftData）が SSoT で、送信は outbox 経由の遅延同期 |
| FR-AE-11 | 保存に失敗したら画面を閉じず、入力を残したまま `ErrorBar` に理由を出す（作成フォームと同じ挙動 = `AddApplicationView.swift:31-34,195-201`） |
| FR-AE-12 | 削除済み / 存在しない申込は編集できない（`.notFound`）。編集画面を開いた後にレコードが消えた場合はエラーを出して閉じる |
| FR-AE-13 | 保存後、詳細画面・一覧・ツアー表・ホームの表示が即座に新しい値になる |
| FR-AE-14 | ステータスと座席は編集画面にも置く。詳細画面のワンタップ切替（R3-1）と座席インライン編集（R3-2）は現状のまま残す |

## 3. 非機能要件・制約

| ID | 内容 |
|---|---|
| NFR-1 | 既存の申込追加フローの振る舞いを変えない（フォーム抽出リファクタを伴うため回帰確認を必須にする） |
| NFR-2 | `Features` は `DataStore` / `Networking` を直接参照しない。注入は Composition Root のみ（IOS-5） |
| NFR-3 | `Domain` に SwiftData を持ち込まない。差分計算などの振る舞いロジックは `Domain` の純粋関数に置き XCTest で検証する |
| NFR-4 | 3 層契約（Prisma ↔ NestJS ↔ iOS）を片側だけ変えない |
| C-1 | BE の `PATCH /v1/applications/:id` は `event_id` / `tour_id` の付け替えを受け付けない（`update-application.dto.ts:27-31`）。付け替えは同期 push（`POST /v1/sync/push` の `events` upsert）でのみ表現される |
| C-2 | iOS の実際の書き込み経路は REST の PATCH ではなく **ローカル書き込み + `POST /v1/sync/push`**（`AppEnvironment.swift:128-131`、`SwiftDataApplicationRepository`）。BE の PATCH は既存契約として維持するが本機能では使わない |
| C-3 | Tour は `POST /v1/tours` を持たない。作成経路は申込の find-or-create のみ（`tours.service.ts:29`） |
| C-4 | `rep_membership_id` は送らない（FR-AP-7 / `ApplicationStore.swift:413-415`） |

## 4. スコープ外

- 申込の削除 UI（Q5）
- `round_name` / `ticket_count` / `price_yen` の入力（Q6）
- ツアー / 公演を単体で編集する専用画面（ツアー表からの一括編集など）
- 共有ボード側（受け取り側）の編集経路 — 既存の `SharedBoard` の write 権限とは別物
- 同期 push のバッチ挙動の改善（§6 R-1 として記録のみ）

## 5. 受入基準

| AC-ID | 基準 | 検証方法 |
|---|---|---|
| AC-AE-01 | 申込詳細に「編集」があり、押すと現在値が入った編集画面が開く | 手動 |
| AC-AE-02 | 同行者を 1 人追加して保存すると、詳細画面の同行者が 1 人増える | 手動 + DataStore テスト |
| AC-AE-03 | 同行者を 1 人削除して保存すると、その同行者だけが消え、残りの `position` が 0 起点連番になる | Domain テスト + DataStore テスト |
| AC-AE-04 | 既存同行者の表示名だけを変えた場合、companion の `id` が変わらない | Domain テスト |
| AC-AE-05 | 同行者を一切触らずに他項目だけ変えた場合、`companions` は送信されず既存行の `updated_at` も動かない | Domain テスト（patch が `.unchanged`）+ DataStore テスト |
| AC-AE-06 | 代表者と同じ名義 / 重複名義 / 4 人目は保存されない（作成時と同じ正規化） | Domain テスト |
| AC-AE-07 | 公演名・会場・公演日を変えると、同じ公演を参照する他の申込の表示も変わる | 手動 |
| AC-AE-08 | 同じ公演を参照する他申込があるとき、保存前に件数付きの注意文が出る | 手動 |
| AC-AE-09 | ツアー名を既存の別ツアー名に変えると、その公演が既存ツアーへ移り、**新しい Tour は増えない**。元のツアー名は変わらない | Domain/DataStore テスト + 手動 |
| AC-AE-10 | ツアー名を未使用の名前に変えると Tour が 1 件だけ増え、他申込のツアー名は変わらない | DataStore テスト |
| AC-AE-11 | 機内モードで編集して保存できる。オンライン復帰後にサーバへ反映される | 手動（2 端末 or DB 確認） |
| AC-AE-12 | 保存が失敗した場合、画面は閉じず入力が残り、`ErrorBar` に理由が出る | 手動 |
| AC-AE-13 | 存在しない / 削除済み申込の編集保存は `.notFound` になり、ローカルに新規行を作らない | DataStore テスト |
| AC-AE-14 | 編集画面で status / seat を変えても、詳細画面の既存トグル・インライン編集は従来どおり動く | 手動 |
| AC-AE-15 | 申込追加フロー（新規作成）の挙動が従来と同じ | 手動（リファクタ回帰） |

## 6. リスク・未検証事項

| ID | 内容 |
|---|---|
| R-1 | `POST /v1/sync/push` は全 mutation を**単一 interactive transaction** で処理する（`sync.service.ts:99-159`）。Prisma の unique 違反等が起きた場合、per-mutation の try/catch で `rejected` に落とす作りだが、PostgreSQL はエラー後にトランザクションを abort するため後続 mutation も巻き添えになる可能性がある。**未検証**。Q2-B（リネームしない）を採るため `tours_owner_name_uniq` を踏む確率は下がるが、リスクとして残る |
| R-2 | 同期 push の `events` upsert は `tour_id` の所有者検証をしていない（`sync.service.ts:247-253`）。既存挙動であり本機能で悪化はしないが、BE-4 観点の宿題として記録する |
| R-3 | `EventPatch` に `tourID` が無いため、FR-AE-9 の付け替えは既存 API では表現できない。Domain / DataStore 側の拡張が必要（`plan.md` の設計判断 D-3） |
