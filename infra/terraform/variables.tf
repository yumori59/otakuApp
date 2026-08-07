variable "project_id" {
  description = "GCP プロジェクトID。プロジェクト自体は手動作成済み前提（docs/12-app-store-release.md §6.2）。"
  type        = string
}

variable "region" {
  description = "リージョン。docs/08-compliance-risk.md の越境移転回避方針により東京固定。"
  type        = string
  default     = "asia-northeast1"
}

variable "service_name" {
  description = "Cloud Run サービス名。"
  type        = string
  default     = "meigicho-api"
}

variable "artifact_repo_name" {
  description = "Artifact Registry の Docker リポジトリ名。"
  type        = string
  default     = "meigicho"
}

variable "github_repository" {
  description = "WIF の attribute condition に使う \"owner/repo\" 形式。例: \"yourname/meigicho\"。"
  type        = string
}

# --- Cloud Run 実行設定（docs/06-infrastructure.md §4.1 の推奨値） ---

variable "cpu" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "512Mi"
}

variable "concurrency" {
  type    = number
  default = 80
}

variable "timeout_seconds" {
  type    = number
  default = 30
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 10
}

# --- アプリの非機密設定（docker-compose.yml の api.environment と同じキー。
#     秘密値は secrets.tf の Secret Manager 側で管理し、ここには含めない） ---

variable "cors_origins" {
  description = "カンマ区切りの許可オリジン。"
  type        = string
}

variable "apple_client_id" {
  type = string
}

variable "apple_issuer" {
  type    = string
  default = "https://appleid.apple.com"
}

variable "apple_jwks_url" {
  type    = string
  default = "https://appleid.apple.com/auth/keys"
}

variable "apple_team_id" {
  type    = string
  default = ""
}

variable "apple_key_id" {
  type    = string
  default = ""
}

variable "google_client_ids" {
  type = string
}

variable "google_issuer" {
  type    = string
  default = ""
}

variable "google_jwks_url" {
  type    = string
  default = "https://www.googleapis.com/oauth2/v3/certs"
}

variable "share_base_url" {
  type = string
}

variable "resend_from_email" {
  type = string
}

variable "jwt_access_ttl_seconds" {
  type    = string
  default = "3600"
}

variable "refresh_ttl_days" {
  type    = string
  default = "90"
}
