# GCS バケット — アカウントアイコン画像（avatar-upload）
# 設計詳細: docs/plans/avatar-upload/storage-design.md §2

resource "google_storage_bucket" "avatars" {
  project  = var.project_id
  name     = "${var.project_id}-avatars"
  location = var.region

  storage_class = "STANDARD"

  # ACL ではなく IAM のみで制御する（オブジェクト単位の公開設定ミスを防ぐ）
  uniform_bucket_level_access = true

  # allUsers への legacyObjectReader 付与のため enforced にしない
  public_access_prevention = "inherited"

  # 削除したアバターを残さない（docs/08 保存期間最小化）
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  versioning {
    enabled = false
  }

  # terraform destroy の事故防止
  force_destroy = false

  labels = {
    app     = "meigicho"
    purpose = "avatars"
  }

  depends_on = [google_project_service.required]
}

# Cloud Run 実行 SA — アップロード・置換・削除
# roles/storage.objectUser = objects.create / get / delete / update / list
# バケット設定・IAM は変更できない
resource "google_storage_bucket_iam_member" "api_runtime_object_user" {
  bucket = google_storage_bucket.avatars.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.api_runtime.email}"
}

# 公開読み取り — objects.get のみ（objects.list は含まない）
# roles/storage.objectViewer は objects.list を含み全オブジェクトを列挙できるため使わない
resource "google_storage_bucket_iam_member" "public_reader" {
  bucket = google_storage_bucket.avatars.name
  role   = "roles/storage.legacyObjectReader"
  member = "allUsers"
}
