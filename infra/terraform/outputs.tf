output "cloud_run_url" {
  description = "デプロイされた Cloud Run サービスの URL。iOS project.yml の Release API_BASE_URL に設定する。"
  value       = google_cloud_run_v2_service.api.uri
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}

output "ci_deploy_service_account_email" {
  description = "deploy-api.yml の GCP_CI_DEPLOY_SERVICE_ACCOUNT に設定する。"
  value       = google_service_account.ci_deploy.email
}

output "terraform_deployer_service_account_email" {
  description = "terraform-apply.yml の GCP_TERRAFORM_SERVICE_ACCOUNT に設定する。"
  value       = google_service_account.terraform_deployer.email
}

output "workload_identity_provider" {
  description = "GitHub Actions の google-github-actions/auth に渡す provider リソース名。"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "secret_manager_secret_ids" {
  description = "値を投入する必要がある Secret Manager のシークレット一覧（infra/terraform/README.md 参照）。"
  value       = [for s in google_secret_manager_secret.this : s.secret_id]
}
