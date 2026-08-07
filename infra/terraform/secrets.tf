# Secret Manager: 機密値そのものは Terraform で入れない（state に平文で残るのを避けるため）。
# ここでは「箱」だけを作り、値は init.tf の README 手順で手動投入する
# （`echo -n "<値>" | gcloud secrets versions add <name> --data-file=-`）。
# バージョンが1つも無い間は Cloud Run の起動時参照が失敗する＝未設定のまま本番に出ない安全弁になる。

locals {
  # キー: Secret Manager 上のリソース名 / 値: docker-compose.yml の api.environment と対応する env var 名
  # （env-coverage.spec.ts が正とする env var 名のうち、機密性が高いもの）
  secret_env_map = {
    database-url              = "DATABASE_URL"
    jwt-access-secret         = "JWT_ACCESS_SECRET"
    apple-private-key         = "APPLE_PRIVATE_KEY"
    revenuecat-webhook-secret = "REVENUECAT_WEBHOOK_SECRET"
    resend-api-key            = "RESEND_API_KEY"
  }
}

resource "google_secret_manager_secret" "this" {
  for_each = local.secret_env_map

  project   = var.project_id
  secret_id = each.key

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "runtime_accessor" {
  for_each = local.secret_env_map

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api_runtime.email}"
}
