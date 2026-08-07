resource "google_artifact_registry_repository" "api" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repo_name
  format        = "DOCKER"
  description   = "参戦名義帳 BE (NestJS) のコンテナイメージ"

  depends_on = [google_project_service.required]
}
