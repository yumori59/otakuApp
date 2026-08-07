output "cloud_run_url" {
  description = "デプロイされた Cloud Run サービスの URL。iOS project.yml の Release API_BASE_URL に設定する。"
  value       = google_cloud_run_v2_service.api.uri
}

output "artifact_registry_repo" {
  description = "GitHub Variables の GCP_ARTIFACT_REPO に設定する（deploy-api.yml がイメージ名の前半として使う）。"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}

output "ci_deploy_service_account_email" {
  description = "GitHub Variables の GCP_CI_DEPLOY_SA に設定する（deploy-api.yml が使う）。"
  value       = google_service_account.ci_deploy.email
}

output "terraform_deployer_service_account_email" {
  description = "GitHub Variables の GCP_TERRAFORM_DEPLOYER_SA に設定する（terraform-apply.yml が使う）。"
  value       = google_service_account.terraform_deployer.email
}

output "terraform_planner_service_account_email" {
  description = "GitHub Variables の GCP_TERRAFORM_PLANNER_SA に設定する（terraform-plan.yml が使う・読み取り専用）。"
  value       = google_service_account.terraform_planner.email
}

output "workload_identity_provider" {
  description = "GitHub Variables の GCP_WIF_PROVIDER に設定する（google-github-actions/auth に渡す provider リソース名）。"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "secret_manager_secret_ids" {
  description = "値を投入する必要がある Secret Manager のシークレット一覧（infra/terraform/README.md 参照）。"
  value       = [for s in google_secret_manager_secret.this : s.secret_id]
}
