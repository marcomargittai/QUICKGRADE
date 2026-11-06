import CoreGraphics
import XCTest
@testable import QuickGradeCore

final class SelectionMaskTests: XCTestCase {
    func testDotStrokeProducesWhitePixels() {
        let stroke = SelectionStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.08, erases: false)
        let size = CGSize(width: 64, height: 48)
        let mask = SelectionMask.strokeMask(strokes: [stroke], size: size)
        XCTAssertNotNil(mask)
        XCTAssertEqual(mask?.width, 64)
        XCTAssertEqual(mask?.height, 48)
        XCTAssertGreaterThan(keepCount(mask!), 0)
    }

    func testEraseStrokeClearsDot() {
        let dot = SelectionStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.08, erases: false)
        let erase = SelectionStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.1, erases: true)
        let size = CGSize(width: 64, height: 48)
        let mask = SelectionMask.strokeMask(strokes: [dot, erase], size: size)
        if let mask {
            XCTAssertLessThan(keepCount(mask), 8)
        }
    }

    func testPointsOutsideUnitAreClamped() {
        let stroke = SelectionStroke(points: [CGPoint(x: 4, y: -2)], radius: 0.06, erases: false)
        let size = CGSize(width: 32, height: 32)
        let mask = SelectionMask.strokeMask(strokes: [stroke], size: size)
        XCTAssertNotNil(mask)
        XCTAssertGreaterThan(keepCount(mask!), 0)
    }

    func testCutoutWithNoStrokesThrows() {
        let source = solidImage(width: 16, height: 16)
        XCTAssertThrowsError(try SelectionMask.cutout(source: source, strokes: [])) { error in
            XCTAssertEqual(error as? SelectionMaskError, .failed)
        }
    }

    private func keepCount(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.filter { $0 > 16 }.count
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            pixels[offset] = 120
            pixels[offset + 1] = 140
            pixels[offset + 2] = 160
            pixels[offset + 3] = 255
        }
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
