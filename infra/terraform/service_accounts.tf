# --- Cloud Run 実行時のサービスアカウント（アプリ自身が使う） ---

resource "google_service_account" "api_runtime" {
  project      = var.project_id
  account_id   = "meigicho-api"
  display_name = "meigicho API runtime"

  depends_on = [google_project_service.required]
}

# --- GitHub Actions が gcloud/docker を叩くためのサービスアカウント（WIF 経由で借用） ---

resource "google_service_account" "ci_deploy" {
  project      = var.project_id
  account_id   = "ci-deploy"
  display_name = "GitHub Actions deploy (WIF)"

  depends_on = [google_project_service.required]
}

# CI は Cloud Run の新リビジョンをデプロイできる（プロジェクト全体の管理者権限は渡さない）
resource "google_project_iam_member" "ci_deploy_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

# CI はビルドしたイメージを Artifact Registry へ push できる
resource "google_project_iam_member" "ci_deploy_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

# Cloud Run へのデプロイ時、実行時 SA (api_runtime) を「このサービスアカウントとして起動してよい」と
# 明示的に許可する必要がある（actAs 相当）。プロジェクト全体ではなく対象 SA だけに絞る。
resource "google_service_account_iam_member" "ci_deploy_can_act_as_runtime" {
  service_account_id = google_service_account.api_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.ci_deploy.email}"
}
