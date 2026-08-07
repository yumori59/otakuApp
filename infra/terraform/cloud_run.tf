resource "google_cloud_run_v2_service" "api" {
  project  = var.project_id
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.api_runtime.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      # CI (deploy-api.yml) が `gcloud run deploy --image=...` で実イメージに差し替える。
      # Terraform 側はこのプレースホルダのまま固定し、image の差分では変更を要求しない
      # （下の lifecycle.ignore_changes 参照）。
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # --- 非機密設定（docker-compose.yml api.environment と同じキー） ---
      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "PORT"
        value = "8080"
      }
      env {
        name  = "CORS_ORIGINS"
        value = var.cors_origins
      }
      env {
        name  = "JWT_ACCESS_TTL_SECONDS"
        value = var.jwt_access_ttl_seconds
      }
      env {
        name  = "REFRESH_TTL_DAYS"
        value = var.refresh_ttl_days
      }
      env {
        name  = "APPLE_CLIENT_ID"
        value = var.apple_client_id
      }
      env {
        name  = "APPLE_ISSUER"
        value = var.apple_issuer
      }
      env {
        name  = "APPLE_JWKS_URL"
        value = var.apple_jwks_url
      }
      env {
        name  = "APPLE_TEAM_ID"
        value = var.apple_team_id
      }
      env {
        name  = "APPLE_KEY_ID"
        value = var.apple_key_id
      }
      env {
        name  = "GOOGLE_CLIENT_IDS"
        value = var.google_client_ids
      }
      env {
        name  = "GOOGLE_ISSUER"
        value = var.google_issuer
      }
      env {
        name  = "GOOGLE_JWKS_URL"
        value = var.google_jwks_url
      }
      env {
        name  = "SHARE_BASE_URL"
        value = var.share_base_url
      }
      env {
        name  = "RESEND_FROM_EMAIL"
        value = var.resend_from_email
      }

      # --- 機密値: Secret Manager から解決（secrets.tf で作った「箱」の最新バージョン） ---
      dynamic "env" {
        for_each = local.secret_env_map
        content {
          name = env.value
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this[env.key].secret_id
              version = "latest"
            }
          }
        }
      }
    }

    timeout = "${var.timeout_seconds}s"

    max_instance_request_concurrency = var.concurrency
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [
      # CI が gcloud run deploy でリビジョンを更新するたびに Terraform の plan が
      # 「差分あり」を出さないようにする（image はコード側のデプロイが正）。
      template[0].containers[0].image,
    ]
  }

  depends_on = [
    google_project_service.required,
    google_secret_manager_secret_iam_member.runtime_accessor,
  ]
}

# --allow-unauthenticated 相当。認可はアプリ層 JWT で行う（docs/06-infrastructure.md §4.2）。
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
