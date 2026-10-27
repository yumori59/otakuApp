#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 端末側のアバター画像変換。
/// PhotosPicker で取得した Data を正方形 JPEG に変換する。
/// ImageIO / CoreGraphics のみに依存し UIKit に依存しない（CoreTests で単体テスト可能）。
public enum AvatarImageEncoder {

    public enum Error: Swift.Error, Equatable {
        case unreadableImage
        case encodingFailed
    }

    public static let side = 512

    /// `data` を `side × side` px の JPEG に変換して返す。
    ///
    /// - Parameters:
    ///   - data: PhotosPickerItem から取得した元データ（HEIC / JPEG / PNG など）
    ///   - side:  出力辺長（px）。既定 512
    ///   - quality: JPEG 品質 0〜1。既定 0.85
    /// - Throws:
    ///   - `Error.unreadableImage`: デコード不能なデータ
    ///   - `Error.encodingFailed`: 正方形クロップまたは JPEG エンコードに失敗
    public static func squareJPEG(from data: Data, side: Int = side, quality: Double = 0.85) throws -> Data {
        // CGImageSource でデコード。HEIC / JPEG / PNG / WebP など ImageIO が対応する形式を受け付ける。
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw Error.unreadableImage
        }

        // サムネイル生成: EXIF Orientation 適用 + 最大 2048px まで縮小してデコード（メモリ節約）
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw Error.unreadableImage
        }

        // 短辺を基準に中央正方形クロップ
        let w = thumbnail.width
        let h = thumbnail.height
        let minDim = min(w, h)
        let cropRect = CGRect(
            x: (w - minDim) / 2,
            y: (h - minDim) / 2,
            width: minDim,
            height: minDim
        )
        guard let cropped = thumbnail.cropping(to: cropRect) else {
            throw Error.encodingFailed
        }

        // sRGB の `side × side` コンテキストに白で塗りつぶしてから描画
        // premultipliedLast: RGBA 8bit。透過 PNG の alpha を白に合成する。
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw Error.encodingFailed
        }
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

        guard let finalImage = ctx.makeImage() else {
            throw Error.encodingFailed
        }

        // JPEG エンコード。メタデータ辞書を渡さない = EXIF/GPS/XMP を出力しない。
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.encodingFailed
        }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, finalImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.encodingFailed
        }

        return outputData as Data
    }
}
#endif
