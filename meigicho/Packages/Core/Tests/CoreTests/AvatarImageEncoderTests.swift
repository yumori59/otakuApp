import XCTest
@testable import Core
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// AC-AV-32: AvatarImageEncoder が横長・縦長・小さい画像を 512×512 JPEG に変換し、
/// 不正データでは `.unreadableImage` を投げる。
final class AvatarImageEncoderTests: XCTestCase {

#if canImport(CoreGraphics)

    // MARK: - 正常系

    func testLandscapeImageProducesSquare() throws {
        let input = try XCTUnwrap(makeTestJPEG(width: 800, height: 400))
        let output = try AvatarImageEncoder.squareJPEG(from: input)
        let (w, h) = try dimensions(of: output)
        XCTAssertEqual(w, 512)
        XCTAssertEqual(h, 512)
    }

    func testPortraitImageProducesSquare() throws {
        let input = try XCTUnwrap(makeTestJPEG(width: 400, height: 800))
        let output = try AvatarImageEncoder.squareJPEG(from: input)
        let (w, h) = try dimensions(of: output)
        XCTAssertEqual(w, 512)
        XCTAssertEqual(h, 512)
    }

    func testSmallImageProducesSquare() throws {
        let input = try XCTUnwrap(makeTestJPEG(width: 100, height: 100))
        let output = try AvatarImageEncoder.squareJPEG(from: input)
        let (w, h) = try dimensions(of: output)
        XCTAssertEqual(w, 512)
        XCTAssertEqual(h, 512)
    }

    func testOutputIsJPEG() throws {
        let input = try XCTUnwrap(makeTestJPEG(width: 300, height: 300))
        let output = try AvatarImageEncoder.squareJPEG(from: input)
        // JPEG マジックバイト: FF D8 FF
        XCTAssertEqual(output.prefix(2), Data([0xFF, 0xD8]))
    }

    func testCustomSideParameter() throws {
        let input = try XCTUnwrap(makeTestJPEG(width: 800, height: 600))
        let output = try AvatarImageEncoder.squareJPEG(from: input, side: 256)
        let (w, h) = try dimensions(of: output)
        XCTAssertEqual(w, 256)
        XCTAssertEqual(h, 256)
    }

    func testDefaultSideConstant() {
        XCTAssertEqual(AvatarImageEncoder.side, 512)
    }

    // MARK: - エラー系

    func testInvalidDataThrowsUnreadableImage() {
        let garbage = Data("not an image at all".utf8)
        XCTAssertThrowsError(try AvatarImageEncoder.squareJPEG(from: garbage)) { error in
            XCTAssertEqual(error as? AvatarImageEncoder.Error, .unreadableImage)
        }
    }

    func testEmptyDataThrowsUnreadableImage() {
        XCTAssertThrowsError(try AvatarImageEncoder.squareJPEG(from: Data())) { error in
            XCTAssertEqual(error as? AvatarImageEncoder.Error, .unreadableImage)
        }
    }

    // MARK: - ヘルパー

    private func makeTestJPEG(width: Int, height: Int) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.setFillColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    private func dimensions(of jpegData: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let wNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let hNum = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw AvatarImageEncoder.Error.unreadableImage
        }
        return (wNum.intValue, hNum.intValue)
    }

#endif
}
