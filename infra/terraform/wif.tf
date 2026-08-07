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
    # 「どのワークフローファイルから発行されたトークンか」。
    # 例: "owner/repo/.github/workflows/terraform-apply.yml@refs/heads/main"
    # terraform_deployer（強権限）の借用をこの値で 1 ワークフローに限定する。
    "attribute.job_workflow_ref" = "assertion.job_workflow_ref"
  }

  # このリポジトリ以外からのトークンは一切受け付けない。
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  # プール内の「このリポジトリの全ワークフロー／全ブランチ」を指す principalSet。
  # provider の attribute_condition でリポジトリは既に固定されているため、
  # これは実質「このリポジトリの GitHub Actions すべて」を意味する。
  wif_repo_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"

  # terraform-apply.yml（main ブランチ上）から発行されたトークンだけを指す principalSet。
  wif_terraform_apply_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.job_workflow_ref/${var.github_repository}/.github/workflows/terraform-apply.yml@refs/heads/main"
}

# デプロイ用 SA（Cloud Run のイメージ差し替えのみができる弱い権限）は
# リポジトリ単位で許可する。deploy-api.yml は main への push でしか動かない。
resource "google_service_account_iam_member" "wif_can_impersonate_ci_deploy" {
  service_account_id = google_service_account.ci_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_repo_principal
}
