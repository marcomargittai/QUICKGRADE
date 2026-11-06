import CoreGraphics
import XCTest
@testable import QuickGradeCore

final class ImageTransferTests: XCTestCase {
    func testOpaqueTwoByTwoIsNotTransparent() {
        let image = makeImage(
            pixels: [
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 255,
                10, 20, 30, 255
            ],
            width: 2,
            height: 2
        )
        XCTAssertFalse(ImageTransfer.hasTransparency(image))
    }

    func testTwoByTwoWithOneClearPixelIsTransparent() {
        let image = makeImage(
            pixels: [
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 0,
                10, 20, 30, 255
            ],
            width: 2,
            height: 2
        )
        XCTAssertTrue(ImageTransfer.hasTransparency(image))
    }

    func testExportExtensionJPEGOpaqueKeepsJPEGFamily() {
        let result = ImageTransfer.exportExtension(sourceExtension: "jpeg", transparent: false)
        XCTAssertTrue(result == "jpg" || result == "jpeg")
    }

    func testExportExtensionJPEGTransparentIsPNG() {
        XCTAssertEqual(ImageTransfer.exportExtension(sourceExtension: "jpeg", transparent: true), "png")
    }

    func testExportExtensionHEICTransparentIsPNG() {
        XCTAssertEqual(ImageTransfer.exportExtension(sourceExtension: "heic", transparent: true), "png")
    }

    func testExportExtensionTIFFTransparentIsTIFF() {
        XCTAssertEqual(ImageTransfer.exportExtension(sourceExtension: "tiff", transparent: true), "tiff")
    }

    func testExportExtensionPNGOpaqueIsPNG() {
        XCTAssertEqual(ImageTransfer.exportExtension(sourceExtension: "png", transparent: false), "png")
    }

    func testExportExtensionWebPOpaqueIsJPG() {
        XCTAssertEqual(ImageTransfer.exportExtension(sourceExtension: "webp", transparent: false), "jpg")
    }

    func testPNGDataOfOpaqueImageIsNonNilAndHasPNGSignature() {
        let image = makeImage(
            pixels: [
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 255,
                10, 20, 30, 255
            ],
            width: 2,
            height: 2
        )
        let data = ImageTransfer.pngData(image)
        XCTAssertNotNil(data)
        guard let data else { return }
        XCTAssertGreaterThanOrEqual(data.count, 4)
        XCTAssertEqual(Array(data.prefix(4)), [137, 80, 78, 71])
    }

    private func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage {
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
