terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # バケット名はプロジェクトごとに違うため、ここでは backend の種類だけを宣言する。
  # 実際の接続先は `terraform init -backend-config=bucket=<バケット名>` で渡す
  # （README.md の手順を参照。バケット自体は Terraform 管理外＝先に手動で作る）。
  backend "gcs" {
    prefix = "meigicho/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
