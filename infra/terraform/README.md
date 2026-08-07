# infra/terraform — Cloud Run 本番基盤（IaC）

このディレクトリが Cloud Run・Artifact Registry・Secret Manager・GitHub Actions 用 WIF の**正**。
`docs/06-infrastructure.md` §4 の設計をコード化したもの。詳細な背景・コスト試算は同ドキュメントを参照。

対象外（Terraform管理外）:
- GCPプロジェクト自体の作成・課金アカウント紐付け（[docs/12-app-store-release.md](../../docs/12-app-store-release.md) §6.2 で手動作成する前提）
- Supabase（DBホスティングはSupabase側で完結。§6.1参照）
- Terraform の state を置く GCS バケット自体（下記 0 節で先に手動作成する）

---

## 0. 初回だけ・手動で行う準備

### 0.1 state用バケットを作る

Terraform の state をどこかに永続化する必要があるが、そのバケット自体を Terraform では作れない
（鶏と卵）。一度だけ手動で作る:

```bash
gcloud config set project <project_id>
gsutil mb -l asia-northeast1 gs://<project_id>-tfstate
gsutil versioning set on gs://<project_id>-tfstate
```

### 0.2 ローカルから初回 apply する

CI（`terraform-apply.yml`）が使う専用サービスアカウント（`terraform_deployer`）はこの Terraform 自身が
作るリソースなので、**最初の1回だけは自分の gcloud ユーザー権限で apply する**。

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # 値を埋める
terraform init -backend-config="bucket=<project_id>-tfstate"
terraform plan
terraform apply
```

`terraform init` で生成される `.terraform.lock.hcl` はコミットする（プロバイダバージョンの再現性のため）。
`terraform.tfvars` はコミットしない（`.gitignore` 済み）。

### 0.3 Secret Manager に値を投入する

`terraform apply` はシークレットの「箱」だけ作る（値は state に残さない設計）。値は手動で入れる:

```bash
echo -n "<Supabaseのpooler接続文字列>" | gcloud secrets versions add database-url --data-file=-
echo -n "<ランダムな長い文字列>"        | gcloud secrets versions add jwt-access-secret --data-file=-
echo -n "<AuthKey_XXXX.p8 の中身>"      | gcloud secrets versions add apple-private-key --data-file=-
echo -n "<RevenueCat Webhook Secret>"  | gcloud secrets versions add revenuecat-webhook-secret --data-file=-
echo -n "<Resend API Key>"             | gcloud secrets versions add resend-api-key --data-file=-
```

バージョンが1つも無い間は Cloud Run の起動時にシークレット参照が失敗し**サービスが起動しない**。
これは意図的な安全弁（未設定のまま本番公開されることを防ぐ）。

### 0.4 GitHub リポジトリに Terraform の出力値を設定する

```bash
terraform output
```

の結果を GitHub リポジトリの **Settings → Secrets and variables → Actions → Variables**
（いずれも機密情報ではなくリソース識別子なので Secrets ではなく Variables に置く）に登録する:

| GitHub Variables (`vars.*`) | Terraform output |
|---|---|
| `GCP_PROJECT_ID` | `var.project_id`（tfvarsの値） |
| `GCP_REGION` | `var.region`（既定 `asia-northeast1`） |
| `GCP_WIF_PROVIDER` | `workload_identity_provider` |
| `GCP_CI_DEPLOY_SA` | `ci_deploy_service_account_email` |
| `GCP_TERRAFORM_DEPLOYER_SA` | `terraform_deployer_service_account_email` |
| `GCP_ARTIFACT_REPO` | `artifact_registry_repo` |
| `GCP_SERVICE_NAME` | `meigicho-api`（`var.service_name` の既定値） |
| `CORS_ORIGINS` / `GOOGLE_CLIENT_IDS` / `SHARE_BASE_URL` / `RESEND_FROM_EMAIL` / `APPLE_CLIENT_ID` | `terraform.tfvars` と同じ値（`terraform-plan.yml`/`terraform-apply.yml` が `TF_VAR_*` として渡す） |

加えて **Settings → Secrets and variables → Actions → Secrets** に:

| GitHub Secrets | 値 |
|---|---|
| `TF_STATE_BUCKET` | 0.1 で作った `<project_id>-tfstate` |

`terraform-apply.yml` は `environment: production` を指定している。GitHub の
**Settings → Environments → production** で Required reviewers を設定すると、
`workflow_dispatch` 実行時にもう一段階の人手承認を挟める（任意だが推奨）。

---

## 1. 通常運用（0番の初回セットアップ後）

- **BEコードのデプロイ**: `apps/api/**` を含む変更を `main` にマージすると `deploy-api.yml` が自動実行される
  （build → push → `gcloud run deploy`）。Terraform には触れない
- **インフラ変更**（Cloud Run設定・Secret Manager・IAM等）: `infra/terraform/**` を変更してPRを出すと
  `terraform-plan.yml` が自動で `terraform plan` を実行しログに出す。**apply はしない**（レビュー用）
- **インフラ変更の適用**: `terraform-apply.yml` を GitHub Actions の画面から**手動実行**する
  （`workflow_dispatch`）。事故防止のため自動applyにはしていない

## 2. セキュリティ上の注意

- `terraform_deployer` サービスアカウントは IAM・Secret Manager・Cloud Run を管理できる強い権限を持つ
  （`terraform_deployer.tf` 参照）。WIF はリポジトリ単位の制限のみで、ワークフロー単位までは絞っていない。
  実際の安全弁は **`terraform apply` が `workflow_dispatch`（人間が手動で押す）でしか起動しない**こと
- より厳密に分離したい場合は `wif.tf` の `attribute_condition` に `assertion.job_workflow_ref` を追加する

## 3. DBマイグレーションについて（Terraform管理外）

このTerraformはCloud Run側のみを扱う。DBスキーマの反映（`prisma migrate deploy` 等）は含めていない
（`apps/api/prisma/migrations/` が未整備のため。詳細は `docs/12-app-store-release.md` §6.1 と
`apps/api/docker-entrypoint.sh` のコメント参照。本番コンテナは `NODE_ENV=production` のとき
起動時の自動 `db push` をスキップする）。
