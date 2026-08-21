import SwiftUI
import DesignSystem
import Domain

/// ツアー編集フォーム（T5・`docs/plans/tour-edit-and-delete/plan.md` D-2）。
///
/// `AddMembershipView` と同じ「小さい単一目的シート」の形（ツアー名 + アーティスト名 + 保存/キャンセルのみ）。
/// `ApplicationFormView`（12 項目の申込フォーム）は再利用しない — ツアー名編集の意味が異なる
/// （`ApplicationEditPlanner.makeTourDraft` は付け替え用で別物。D-2 却下理由）。
/// 差分計算はここでは行わず `ApplicationStore.updateTour(id:name:artistName:)` に委ねる。
struct TourFormView: View {
    let tourID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(\.themeStore) private var theme

    @State private var name = ""
    @State private var artistName = ""
    @State private var originalName = ""
    @State private var originalArtistName = ""
    @State private var isSaving = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedArtistName: String {
        artistName.trimmingCharacters(in: .whitespaces)
    }

    /// 保存ボタンの活性条件（FR-TE-3 / FR-TE-7 / AC-TE-19）: ツアー名が空でない かつ 元の値と違う
    private var canSave: Bool {
        !trimmedName.isEmpty && (trimmedName != originalName || trimmedArtistName != originalArtistName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 保存に失敗したらシートは閉じず、理由をここに出す（同名衝突・オフライン時など = AC-TE-04）
                if let error = applicationStore.writeError {
                    ErrorBar(errorMessage(for: error)).padding(.bottom, 12)
                }
                FormSectionLabel("ツアー情報")
                FormCard {
                    FormRow("ツアー名") {
                        FormTextField("例）STELLARIS ARENA TOUR 2026", text: $name)
                    }
                    FormRow("アーティスト / グループ") {
                        FormTextField("例）STELLARIS", text: $artistName)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("ツアーを編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存") { save() }
                        .font(DSFont.bodyBold)
                        .disabled(!canSave)
                }
            }
        }
        .onAppear { populateInitialValues() }
    }

    /// フォームを開いた時点で現在値を代入する。既に削除済み / 存在しないツアーなら閉じる
    /// （`ApplicationFormView.populateInitialValues` の `.edit` と同じ扱い = AC-AE-12 相当）。
    private func populateInitialValues() {
        applicationStore.writeError = nil
        guard let tour = applicationStore.tour(for: tourID) else {
            applicationStore.writeError = .notFound
            dismiss()
            return
        }
        name = tour.name
        artistName = tour.artistNameRaw
        originalName = tour.name
        originalArtistName = tour.artistNameRaw
    }

    /// D-6: 楽観更新はしない。保存中はスピナー、成功したら dismiss、失敗はフォームを開いたままエラーバー
    /// （`MembershipFormView.saveEdit` / `IdentityFormView.saveEdit` と同じ方針）。
    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            let updated = await applicationStore.updateTour(
                id: tourID,
                name: trimmedName,
                artistName: trimmedArtistName.isEmpty ? nil : trimmedArtistName
            )
            isSaving = false
            guard updated != nil else { return }
            dismiss()
        }
    }

    /// `AppError.conflict` はツアー名の同名衝突（`SwiftDataCatalogRepository.updateTour` の D-4 事前チェック）
    /// を指す。`AppError.userMessage` の汎用文言ではなく FR-TE-6 の文言に上書きする
    /// （`AppError.swift` 冒頭の「文脈で出し分けたい箇所は呼び出し側で上書きする」規約に従う）。
    private func errorMessage(for error: AppError) -> String {
        switch error {
        case .conflict:
            return "同じ名前のツアーが既にあります"
        default:
            return error.userMessage
        }
    }
}
