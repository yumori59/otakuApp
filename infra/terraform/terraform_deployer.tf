# `terraform apply` を CI (terraform-apply.yml, workflow_dispatch = 手動トリガーのみ) から
# 実行するための、より強い権限を持つ専用サービスアカウント。
#
# 注意（既知の制約）: この SA も `wif.tf` と同じ Workload Identity Pool
# （リポジトリ単位の attribute_condition）から借用できる。ワークフロー単位までは絞っていないため、
# 「deploy-api.yml では ci_deploy だけを使う／terraform-apply.yml では terraform_deployer だけを使う」
# という区別は **ワークフロー YAML 側の実装規約**によって保たれている。実際の安全弁は
# 「terraform apply は workflow_dispatch（人間が手動で押す）でしか起動しない」こと。
# より厳密に分離したい場合は attribute_condition に `assertion.job_workflow_ref` を足す。

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
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
