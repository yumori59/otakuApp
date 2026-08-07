# レビュー結果 — CI/CD + Terraform IaC 導入

対象: `git diff main...work/infra-cicd`（元コミット `f637950`）
レビュー日: 2026-08-07 / レビュアー: code-reviewer（第三者セッション）
検証: `terraform fmt -check -recursive` / `terraform validate`（provider google v6.50.0、backend未初期化）

## サマリ

- 重大: 4 件 → **本レビュー内ですべて修正済み（再検証で重大 0）**
- 中: 4 件（うち 4 件修正済み）
- 軽微/提案: 5 件（うち 4 件修正済み、1 件は残課題として記載）

---

## 重大 (Must Fix) — すべて修正済み

### 1. `PORT` は Cloud Run の予約環境変数。apply が必ず失敗する

`cloud_run.tf`（旧 39-42 行）が `env { name = "PORT" value = "8080" }` を設定していた。
Cloud Run は `PORT` を `ports.container_port` から自動注入する予約名で、明示指定すると
Admin API が `The following reserved env names were provided: PORT` を返し、
**`terraform apply` も `gcloud run deploy` も通らない**。

修正: 当該 `env` ブロックを削除し、`ports` ブロックに理由コメントを付与（`cloud_run.tf:19-26`）。
`apps/api/src/main.ts:19` は `process.env.PORT ?? 8080` なので挙動は変わらない。

### 2. PR 上の `terraform plan` に書き込み権限 SA を渡していた（権限昇格経路）

`terraform-plan.yml`（旧 31 行）が `GCP_TERRAFORM_DEPLOYER_SA`＝`roles/resourcemanager.projectIamAdmin`
等を持つ SA を借用していた。`terraform plan` は **PR ブランチの HCL（provider 設定・data source）を
CI 上で評価する**ため、PR の内容がそのまま強権限クレデンシャルの文脈で実行される。
「apply は `workflow_dispatch` のみ」という安全弁は、この経路では成立しない。

修正:
- 読み取り専用 SA `terraform_planner` を新設（`terraform_deployer.tf:48-90`）。
  ロールは `browser` / `iam.securityReviewer` / `run.viewer` / `artifactregistry.reader` /
  `secretmanager.viewer`（**値は読めない**）/ `iam.serviceAccountViewer` /
  `iam.workloadIdentityPoolViewer` / `serviceusage.serviceUsageViewer` の read 系のみ。
- `terraform-plan.yml` を planner SA に切替え、`init`/`plan` を `-lock=false`（state バケットに書けないため）。

### 3. WIF の principalSet がコメントの主張より広い（terraform_deployer を誰でも借用できる）

旧 `wif.tf:32-38` は「refs/heads/main から来たトークンにだけ」と書きながら、実際の member は
`attribute.repository/<owner/repo>`＝**このリポジトリの全ブランチ・全ワークフロー**だった。
`terraform_deployer.tf` も同じ広い principalSet を使っており、任意のブランチに置いた
ワークフローからプロジェクト IAM 管理者相当を取得できる状態だった。

修正: `attribute_mapping` に `attribute.job_workflow_ref` を追加（`wif.tf:18-27`）し、
`terraform_deployer` の借用元を
`.../attribute.job_workflow_ref/<owner/repo>/.github/workflows/terraform-apply.yml@refs/heads/main`
に限定（`wif.tf:35-45`, `terraform_deployer.tf:44-48`）。
`ci_deploy` / `terraform_planner` は権限が弱いためリポジトリ単位のまま（コメントを実態に合わせて修正）。

### 4. README の初回セットアップ手順が実行不能（2 か所）

- **(a) apply 順序**: 旧 README は「0.2 apply → 0.3 Secret Manager に値を投入」の順だった。
  値（Secret のバージョン）が無いシークレットを参照する Cloud Run リビジョンは起動に失敗し、
  `google_cloud_run_v2_service` の作成自体がエラーになる。**初回 apply が必ず落ちる**。
  修正: 「(1) `-target` で API 有効化と Secret の箱だけ apply → (2) 値投入 → (3) 本 apply」に変更
  （`README.md` 0.2 / 0.3）。
- **(b) state バケットの権限**: `terraform_deployer` のロール一覧に GCS 権限が 1 つも無く、
  CI の `terraform init`（GCS backend）が 403 になる。バケットは Terraform 管理外なので
  コード側では解決できない。修正: バケット側 IAM を付ける手順を 0.4 として追加
  （deployer に `storage.objectAdmin`、planner に `storage.objectViewer`）。

---

## 中 (Should Fix) — すべて修正済み

1. **`gcloud run deploy` がサービス未作成時に「別物」を作る**（`deploy-api.yml`）。
   Terraform より先に走ると、環境変数もシークレットも実行 SA も無いサービスが勝手に生成され、
   その後の Terraform apply と衝突する。→ `gcloud run services describe` で存在確認してから deploy する
   ガードを追加（`deploy-api.yml:78-80`）。
2. **デプロイ後の疎通確認が無い**。イメージが起動失敗してもワークフローは緑になる。
   → `/health` への `curl -f`（リトライ付き）ステップを追加（`deploy-api.yml:91-99`）。
3. **`outputs.tf` の description に書かれた GitHub Variables 名がワークフローと不一致**。
   `GCP_CI_DEPLOY_SERVICE_ACCOUNT` / `GCP_TERRAFORM_SERVICE_ACCOUNT` と書かれていたが、
   実際は `GCP_CI_DEPLOY_SA` / `GCP_TERRAFORM_DEPLOYER_SA`。→ 全 output の description を実名に統一。
4. **`terraform-apply.yml` の confirm ガードが job-level `if`** だったため、確認文字列を間違えると
   ジョブが skip され**ワークフロー全体は成功表示**になる（実行されたのか失敗したのか分からない）。
   → 明示的に失敗するステップに変更（`terraform-apply.yml:44-50`）。あわせて「これは誤クリック除けであり
   セキュリティ境界ではない」ことを明記。

---

## 軽微 / 提案

1. 修正済: 全ワークフローにトップレベル `permissions: contents: read` を追加（`id-token: write` は
   従来どおり必要な job のみ）。
2. 修正済: `deploy-api.yml` / `terraform-apply.yml` に `concurrency` グループを追加。
   連続マージ時に古いイメージが後勝ちするのを防ぐ。
3. 修正済: `terraform-plan.yml` のヘッダコメントが必要な Variables を 4 個しか挙げていなかった（実際は 8 個）。
   あわせて `terraform fmt -check -recursive` を plan ジョブに追加。
4. 修正済: README の `gsutil` を現行の `gcloud storage` に置換、権限分離表（§2）を追加。
5. **残課題**: `.terraform.lock.hcl` が未コミット。README は「コミットする」と書いているが、まだ初回 init が
   行われていないためファイルが存在しない。GCP 認証が無い環境では意図的に生成物をコミットしない判断とし、
   ユーザーの初回ローカル `terraform init` 後にコミットすること（README 0.2 に記載済み）。

---

## 良かった点

- **env var の網羅性が完全**。`docker-compose.yml` の `api.environment` 20 キーに対し、
  非機密 14 個を `cloud_run.tf` の `env`、機密 5 個を `secrets.tf` の `secret_env_map` 経由の
  `secret_key_ref`、残り 1 個（`PORT`）を Cloud Run 自動注入でカバーしており過不足なし。
  `env-coverage.spec.ts` が守る契約と一致している。
- **シークレット値を Terraform state に入れない設計**（`secrets.tf:1-4`）。「箱だけ作る」判断は正しく、
  `secretAccessor` は `api_runtime` SA のみに付与されている（ci_deploy / terraform_deployer への漏れ無し）。
- `lifecycle.ignore_changes = [template[0].containers[0].image]` による Terraform と CI の役割分担が明確で、
  CI がデプロイしたイメージを Terraform が巻き戻さない。
- `ci_deploy` の権限設計が最小限。`serviceAccountUser` をプロジェクト全体ではなく
  `api_runtime` SA だけに絞っている（`service_accounts.tf:37-41`）。
- `docker-entrypoint.sh` の `NODE_ENV=production` 分岐が正しい。本番の暗黙 `db push --accept-data-loss`
  という**データ損失リスクの発見と封じ込め**は本変更の最大の価値。Dockerfile は `ENV NODE_ENV=production`
  を持ち（`Dockerfile:15`）Cloud Run 側でも明示設定するため二重に担保、docker-compose は
  `NODE_ENV: development` なのでローカル運用は不変。
- ドキュメント（`docs/06` §7 / `docs/12` §6）から実ファイルへの索引化が徹底され、
  陳腐化しやすい手順のコピーが除去されている。

---

## 未検証（環境制約）

- 実 GCP への `terraform plan` / `apply`（クレデンシャル無し）。
  特に **WIF の `attribute.job_workflow_ref` を使った principalSet** は実トークンでの検証ができていない。
  初回は README 手順どおりローカル apply で構築し、`terraform-apply.yml` の手動実行が
  認証段階を通ることを 1 度確認すること。403 になる場合は `job_workflow_ref` の値
  （`<owner/repo>/.github/workflows/terraform-apply.yml@refs/heads/main`）を実 OIDC トークンと突き合わせる。
- `terraform_planner` のロール列挙が plan の全 read を満たすかは実行して初めて確定する。
  403 が出たら不足ロールを `local.terraform_planner_roles` に追加する（`terraform_deployer.tf:60-71` に注記済み）。
