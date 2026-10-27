import SwiftUI
import PhotosUI
import DesignSystem
import Domain
import Core

/// アカウント設定画面のアバター選択・削除 UI（`plan.md` §4.12 / FR-AV-21〜26）。
///
/// `ProfileStore` を Environment から取得し、PhotosPicker → 円形プレビュー → 送信、
/// または確認ダイアログ → 削除、の 2 フローを担う。
struct AvatarPickerSection: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(\.themeStore) private var theme

    @State private var photoItem: PhotosPickerItem?
    /// 端末変換済みの JPEG（プレビュー用）
    @State private var previewJpeg: Data?
    @State private var isPreviewPresented = false
    @State private var isDeleteConfirmPresented = false

    var body: some View {
        HStack(spacing: 8) {
            // 写真を選択 / 写真を変更
            PhotosPicker(
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                actionLabel(profile.avatarURL == nil ? "写真を選択" : "写真を変更", isDestructive: false)
            }
            .buttonStyle(.plain)
            .disabled(profile.isUpdatingAvatar)

            // 写真を削除（設定済みのときのみ）
            if profile.avatarURL != nil {
                Button(role: .destructive) {
                    isDeleteConfirmPresented = true
                } label: {
                    actionLabel("写真を削除", isDestructive: true)
                }
                .buttonStyle(.plain)
                .disabled(profile.isUpdatingAvatar)
            }

            if profile.isUpdatingAvatar {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.bottom, 16)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadAndPreview(item) }
        }
        .sheet(isPresented: $isPreviewPresented) {
            previewSheet
        }
        .confirmationDialog(
            "プロフィール写真を削除しますか？",
            isPresented: $isDeleteConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                Task { await profile.deleteAvatar() }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - ラベル

    @ViewBuilder
    private func actionLabel(_ title: String, isDestructive: Bool) -> some View {
        Text(title)
            .font(DSFont.caption)
            .foregroundStyle(isDestructive ? DS.error : theme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .stroke(isDestructive ? DS.error : DS.Gray.g200, lineWidth: 1)
            )
    }

    // MARK: - 画像変換

    private func loadAndPreview(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self) else {
            profile.errorMessage = "画像を読み込めませんでした"
            return
        }
        guard let jpeg = try? AvatarImageEncoder.squareJPEG(from: raw) else {
            profile.errorMessage = "画像を読み込めませんでした"
            return
        }
        previewJpeg = jpeg
        isPreviewPresented = true
    }

    // MARK: - プレビューシート

    private var previewSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                if let previewJpeg {
                    #if canImport(UIKit)
                    if let uiImage = UIImage(data: previewJpeg) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                    }
                    #endif
                }
                Text("この写真を使いますか？")
                    .font(DSFont.bodyBold)
                    .padding(.top, 8)
                Spacer()
            }
            .navigationTitle("プロフィール写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        isPreviewPresented = false
                        previewJpeg = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("この写真を使う") {
                        guard let jpeg = previewJpeg else { return }
                        isPreviewPresented = false
                        previewJpeg = nil
                        Task { await profile.uploadAvatar(jpegData: jpeg) }
                    }
                    .fontWeight(.semibold)
                    .disabled(previewJpeg == nil || profile.isUpdatingAvatar)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
