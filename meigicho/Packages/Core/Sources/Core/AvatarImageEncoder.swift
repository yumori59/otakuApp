import Foundation
import CoreImage
import CoreGraphics

/// 端末側のアバター画像変換（`api-contract-delta.md` §5 / `plan.md` §4.10）。
///
/// - EXIF 向きを適用
/// - 短辺を基準に中央で正方形クロップ
/// - 指定サイズにリサイズ
/// - JPEG（品質 0.85）で出力
/// - 透過 PNG は白背景で合成（黒潰れ防止）
/// - UIKit に依存しない（macOS / iOS 共通）
public enum AvatarImageEncoder {
    public enum Error: Swift.Error, Equatable {
        /// 入力データが画像として読み込めない。
        case unreadableImage
        /// JPEG エンコードに失敗した。
        case encodingFailed
    }

    /// 出力する一辺のピクセル数（既定）。
    public static let side = 512

    /// 任意の画像データを正方形 JPEG に変換する。
    ///
    /// - Parameters:
    ///   - data: 変換元の画像データ（JPEG / PNG / HEIC 等 ImageIO が読める形式）。
    ///   - side: 出力する正方形の一辺ピクセル数（既定 512）。
    ///   - quality: JPEG 圧縮品質（0.0〜1.0、既定 0.85）。
    /// - Returns: 512×512 JPEG データ。
    /// - Throws: `Error.unreadableImage` / `Error.encodingFailed`
    public static func squareJPEG(from data: Data, side: Int = side, quality: Double = 0.85) throws -> Data {
        // EXIF 向きを自動適用して CIImage に変換する
        guard let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw Error.unreadableImage
        }

        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { throw Error.unreadableImage }

        // 短辺基準で中央正方形クロップ
        let shortSide = min(extent.width, extent.height)
        let cropRect = CGRect(
            x: extent.minX + (extent.width - shortSide) / 2,
            y: extent.minY + (extent.height - shortSide) / 2,
            width: shortSide,
            height: shortSide
        )
        let cropped = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        // 指定サイズへスケール
        let scale = CGFloat(side) / shortSide
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 透過 PNG 対応: 白背景に合成してから JPEG 化
        let white = CIImage(color: CIColor.white).cropped(to: scaled.extent)
        let composited = scaled.composited(over: white)

        // メタデータなし JPEG としてレンダリング
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let sRGB = CGColorSpaceCreateDeviceRGB()
        guard let jpeg = context.jpegRepresentation(
            of: composited,
            colorSpace: sRGB,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else {
            throw Error.encodingFailed
        }
        return jpeg
    }
}
