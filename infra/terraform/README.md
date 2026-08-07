# infra/terraform — Cloud Run 本番基盤（IaC）

このディレクトリが Cloud Run・Artifact Registry・Secret Manager・GitHub Actions 用 WIF の**正**。
`docs/06-infrastructure.md` §4 の設計をコード化したもの。詳細な背景・コスト試算は同ドキュメントを参照。

対象外（Terraform管理外）:
- GCPプロジェクト自体の作成・課金アカウント紐付け（[docs/12-app-store-release.md](../../docs/12-app-store-release.md) §6.2 で手動作成する前提）
- Supabase（DBホスティングはSupabase側で完結。§6.1参照）
- Terraform の state を置く GCS バケット自体（下記 0 節で先に手動作成する）
- DBスキーマの反映（3節参照）

---

## 0. 初回だけ・手動で行う準備

### 0.1 state用バケットを作る

Terraform の state をどこかに永続化する必要があるが、そのバケット自体を Terraform では作れない
（鶏と卵）。一度だけ手動で作る:

```bash
gcloud config set project <project_id>
gcloud storage buckets create gs://<project_id>-tfstate --location=asia-northeast1
gcloud storage buckets update gs://<project_id>-tfstate --versioning
```

### 0.2 初回 apply（2段階に分ける）

CI（`terraform-apply.yml`）が使うサービスアカウントはこの Terraform 自身が作るリソースなので、
**最初の1回だけは自分の gcloud ユーザー権限で apply する**。

Cloud Run はシークレットの**値**（Secret Manager のバージョン）が1つも無いとリビジョンが起動できず、
`terraform apply` がそこで失敗する。そのため **「箱を作る apply」→「値を入れる」→「全部 apply」**
の順で進める。

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # 値を埋める
terraform init -backend-config="bucket=<project_id>-tfstate"

# (1) API 有効化と Secret Manager の「箱」だけ先に作る
terraform apply \
  -target='google_project_service.required' \
  -target='google_secret_manager_secret.this'

# (2) 値を投入する（0.3）

# (3) 残り（Cloud Run 本体・IAM・WIF）を作る
terraform plan
terraform apply
```

`terraform init` で生成される `.terraform.lock.hcl` はコミットする（プロバイダバージョンの再現性のため）。
`terraform.tfvars` はコミットしない（`.gitignore` 済み）。

### 0.3 Secret Manager に値を投入する

Terraform はシークレットの「箱」だけ作る（値を state に残さない設計）。値は手動で入れる:

```bash
echo -n "<Supabaseのpooler接続文字列>" | gcloud secrets versions add database-url --data-file=-
echo -n "<ランダムな長い文字列>"        | gcloud secrets versions add jwt-access-secret --data-file=-
echo -n "<AuthKey_XXXX.p8 の中身>"      | gcloud secrets versions add apple-private-key --data-file=-
echo -n "<RevenueCat Webhook Secret>"  | gcloud secrets versions add revenuecat-webhook-secret --data-file=-
echo -n "<Resend API Key>"             | gcloud secrets versions add resend-api-key --data-file=-
```

未使用のもの（例: Resend をまだ使わない）も**空文字ではなく必ず何かのバージョンを入れる**。
バージョンが無いシークレットを参照したリビジョンは起動に失敗する。

### 0.4 state バケットへのアクセス権を CI 用 SA に与える

state バケットは Terraform 管理外なので、バケット側の IAM も手動で付ける
（`terraform_deployer` のプロジェクトロールには GCS の権限が含まれていない）。
0.2 の apply 後に一度だけ実行する:

```bash
PROJECT_ID=<project_id>
gcloud storage buckets add-iam-policy-binding gs://${PROJECT_ID}-tfstate \
  --member="serviceAccount:terraform-deployer@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gcloud storage buckets add-iam-policy-binding gs://${PROJECT_ID}-tfstate \
  --member="serviceAccount:terraform-planner@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"
```

### 0.5 GitHub リポジトリに Terraform の出力値を設定する

```bash
terraform output
```

の結果を GitHub リポジトリの **Settings → Secrets and variables → Actions → Variables**
（いずれも機密情報ではなくリソース識別子なので Secrets ではなく Variables に置く）に登録する:

| GitHub Variables (`vars.*`) | 値 / 対応する Terraform output |
|---|---|
| `GCP_PROJECT_ID` | `var.project_id`（tfvarsの値） |
| `GCP_REGION` | `var.region`（既定 `asia-northeast1`） |
| `GCP_WIF_PROVIDER` | `workload_identity_provider` |
| `GCP_CI_DEPLOY_SA` | `ci_deploy_service_account_email` |
| `GCP_TERRAFORM_DEPLOYER_SA` | `terraform_deployer_service_account_email` |
| `GCP_TERRAFORM_PLANNER_SA` | `terraform_planner_service_account_email` |
| `GCP_ARTIFACT_REPO` | `artifact_registry_repo` |
| `GCP_SERVICE_NAME` | `meigicho-api`（`var.service_name` の既定値） |
| `CORS_ORIGINS` / `GOOGLE_CLIENT_IDS` / `SHARE_BASE_URL` / `RESEND_FROM_EMAIL` / `APPLE_CLIENT_ID` | `terraform.tfvars` と同じ値（`terraform-plan.yml`/`terraform-apply.yml` が `TF_VAR_*` として渡す） |

加えて **Settings → Secrets and variables → Actions → Secrets** に:

| GitHub Secrets | 値 |
|---|---|
| `TF_STATE_BUCKET` | 0.1 で作った `<project_id>-tfstate` |

`terraform-apply.yml` は `environment: production` を指定している。GitHub の
**Settings → Environments → production** で Required reviewers を設定すると、
`workflow_dispatch` 実行時にもう一段階の人手承認を挟める（**推奨**。2節参照）。

---

## 1. 通常運用（0番の初回セットアップ後）

- **BEコードのデプロイ**: `apps/api/**` を含む変更を `main` にマージすると `deploy-api.yml` が自動実行される
  （test → build → push → `gcloud run deploy` → `/health` 疎通確認）。Terraform には触れない
- **インフラ変更**（Cloud Run設定・Secret Manager・IAM等）: `infra/terraform/**` を変更してPRを出すと
  `terraform-plan.yml` が自動で `terraform plan` を実行しログに出す。**apply はしない**（レビュー用）
- **インフラ変更の適用**: マージ後に `terraform-apply.yml` を GitHub Actions の画面から
  **main ブランチを選んで手動実行**する（`workflow_dispatch`）。事故防止のため自動applyにはしていない
- **Cloud Run の設定を `gcloud run deploy` や Console から直接変えない**（Terraform state とズレる）。
  例外はイメージ（`cloud_run.tf` の `lifecycle.ignore_changes` で Terraform 側が追従しない）

## 2. 権限分離（セキュリティ設計）

| SA | 権限 | 借用できるトークン |
|---|---|---|
| `meigicho-api` (runtime) | Secret Manager の該当シークレットの `secretAccessor` のみ | なし（Cloud Run が使う） |
| `ci-deploy` | `run.developer` + `artifactregistry.writer` + runtime SA への `serviceAccountUser` | このリポジトリの GitHub Actions（`deploy-api.yml` が使用） |
| `terraform-planner` | 読み取り専用ロールのみ（`secretmanager.viewer` = メタデータのみ、値は読めない） | このリポジトリの GitHub Actions（`terraform-plan.yml` が使用） |
| `terraform-deployer` | IAM / Secret Manager / Cloud Run の管理権限（**強い**） | `terraform-apply.yml` @ `refs/heads/main` から発行されたトークンのみ |

`terraform plan` は PR ブランチのコード（provider 設定・data source）を CI 上で評価する＝
**PR の内容がそのまま実行される**。だから plan には読み取り専用の SA しか渡していない。

`terraform-deployer` は `resourcemanager.projectIamAdmin` を持つため理論上は自己昇格できる
（IAM 自体を Terraform で管理する以上避けられない）。実効的な防御は次の3段:

1. WIF 側で借用元を `terraform-apply.yml` @ main に限定（`wif.tf`）
2. 起動が `workflow_dispatch`（人手）のみ
3. GitHub Environment `production` の Required reviewers（0.5 で設定を推奨）

## 3. DBマイグレーションについて（Terraform管理外）

このTerraformはCloud Run側のみを扱う。DBスキーマの反映（`prisma migrate deploy` 等）は含めていない
（`apps/api/prisma/migrations/` が未整備のため。詳細は `docs/12-app-store-release.md` §6.1 と
`apps/api/docker-entrypoint.sh` のコメント参照）。本番コンテナは `NODE_ENV=production` のとき
起動時の自動 `db push` をスキップするので、**スキーマ変更はデプロイ前に人が明示的に実行する**。
