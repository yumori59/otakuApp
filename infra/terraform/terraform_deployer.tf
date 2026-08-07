# `terraform apply` / `terraform plan` を CI から実行するためのサービスアカウント。
#
# 権限分離の方針:
#   - terraform_deployer (強権限・書き込み可) は **terraform-apply.yml から発行された
#     トークンだけ**が借用できる（wif.tf の local.wif_terraform_apply_principal）。
#     terraform-apply.yml は workflow_dispatch（手動）のみで起動する。
#   - terraform_planner (読み取り専用) は PR で自動実行される terraform-plan.yml が使う。
#     `terraform plan` は PR のブランチにあるコード（provider 設定や data source）を評価する＝
#     実質的に PR 提出者のコードを CI 上で実行するため、ここに書き込み権限を渡さない。

resource "google_service_account" "terraform_deployer" {
  project      = var.project_id
  account_id   = "terraform-deployer"
  display_name = "GitHub Actions terraform apply (WIF, manual trigger only)"

  depends_on = [google_project_service.required]
}

locals {
  terraform_deployer_roles = [
    "roles/run.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    # 注意: この SA は自分自身に更に強い権限を付与できる（自己昇格可能）。
    # ただし本 Terraform が IAM バインディングそのものを管理する以上、この権限は避けられない。
    # 実効的な防御は「借用できるのが terraform-apply.yml だけ」＋「起動が手動のみ」＋
    # 「GitHub Environment (production) の Required reviewers」の 3 段。
    "roles/resourcemanager.projectIamAdmin",
  ]
}

resource "google_project_iam_member" "terraform_deployer" {
  for_each = toset(local.terraform_deployer_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_service_account_iam_member" "wif_can_impersonate_terraform_deployer" {
  service_account_id = google_service_account.terraform_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_terraform_apply_principal
}

# --- plan 専用の読み取り専用 SA ---

resource "google_service_account" "terraform_planner" {
  project      = var.project_id
  account_id   = "terraform-planner"
  display_name = "GitHub Actions terraform plan (WIF, read-only)"

  depends_on = [google_project_service.required]
}

locals {
  # basic role (roles/viewer) ではなく、本 Terraform が触るサービスの read ロールだけを列挙する。
  # plan が 403 で落ちたら、落ちた API に対応する *Viewer ロールをここに足す。
  terraform_planner_roles = [
    "roles/browser",
    "roles/iam.securityReviewer", # 各リソースの getIamPolicy（google_*_iam_member の読み取り）
    "roles/run.viewer",
    "roles/artifactregistry.reader",
    "roles/secretmanager.viewer", # メタデータのみ。値 (secretAccessor) は含まない
    "roles/iam.serviceAccountViewer",
    "roles/iam.workloadIdentityPoolViewer",
    "roles/serviceusage.serviceUsageViewer",
  ]
}

resource "google_project_iam_member" "terraform_planner" {
  for_each = toset(local.terraform_planner_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform_planner.email}"
}

# plan は PR ブランチ（refs/pull/N/merge）から動くため ref を固定できない。
# リポジトリ単位で許可し、権限側を読み取り専用に絞ることで釣り合いを取る。
resource "google_service_account_iam_member" "wif_can_impersonate_terraform_planner" {
  service_account_id = google_service_account.terraform_planner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_repo_principal
}
