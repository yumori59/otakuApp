# GitHub Actions が JSON 鍵を使わずに GCP を操作するための Workload Identity Federation。
# docs/06-infrastructure.md §7 の設計をそのまま構築する。

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # このリポジトリ以外からのトークンは一切受け付けない。
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# 上記プールに属し、かつ対象リポジトリの refs/heads/main から来たトークンにだけ、
# ci_deploy サービスアカウントの借用（impersonation）を許可する。
# ブランチ以外（PR等）からの WIF token は deploy 用SAを名乗れない（terraform-plan.yml 側は別権限を検討）。
resource "google_service_account_iam_member" "wif_can_impersonate_ci_deploy" {
  service_account_id = google_service_account.ci_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
