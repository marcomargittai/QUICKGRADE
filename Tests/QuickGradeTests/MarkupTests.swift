import CoreGraphics
import XCTest
@testable import QuickGradeCore

final class MarkupTests: XCTestCase {
    func testDrawingPaintsAlongTheStroke() throws {
        let source = try XCTUnwrap(solid(width: 100, height: 50, gray: 0))
        let stroke = MarkupStroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], width: 0.05, color: .white)
        let drawn = Markup.drawing([stroke], over: source)
        XCTAssertEqual(drawn.width, 100)
        XCTAssertEqual(drawn.height, 50)
        XCTAssertGreaterThan(try red(drawn, x: 50, y: 25), 200)
        XCTAssertLessThan(try red(drawn, x: 50, y: 5), 30)
    }

    func testTopLeftOriginLandsAtTheTop() throws {
        let source = try XCTUnwrap(solid(width: 40, height: 40, gray: 0))
        let dot = MarkupStroke(points: [CGPoint(x: 0.5, y: 0.1)], width: 0.1, color: .white)
        let drawn = Markup.drawing([dot], over: source)
        XCTAssertGreaterThan(try red(drawn, x: 20, y: 4), 200)
        XCTAssertLessThan(try red(drawn, x: 20, y: 36), 30)
    }

    func testNoStrokesReturnsTheSameImage() throws {
        let source = try XCTUnwrap(solid(width: 8, height: 8, gray: 0.5))
        XCTAssertTrue(Markup.drawing([], over: source) === source)
    }

    func testHitFindsPointsOnTheLineOnly() {
        let stroke = MarkupStroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], width: 0.02, color: .pink)
        XCTAssertTrue(Markup.hits(stroke, at: CGPoint(x: 0.5, y: 0.505), aspect: 1, slack: 0))
        XCTAssertFalse(Markup.hits(stroke, at: CGPoint(x: 0.5, y: 0.7), aspect: 1, slack: 0))
    }

    func testOldSettingsWithCutoutStillLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GradeSettings(exposure: 0.4))) as! [String: Any]
        json["removeBackground"] = true
        json["selectionReach"] = 0.7
        json["selectionStrokes"] = [["points": [[0.5, 0.5]], "radius": 0.1, "erases": false]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: data)
        XCTAssertEqual(decoded.exposure, 0.4)
        XCTAssertTrue(decoded.markup.isEmpty)
    }

    func testMarkupRoundTrips() throws {
        var settings = GradeSettings.neutral
        settings.markup = [MarkupStroke(points: [CGPoint(x: 0.2, y: 0.3)], width: MarkupSize.bold.width, color: .blue)]
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.isNeutral)
    }

    private func solid(width: Int, height: Int, gray: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Red channel at (x, y), y counted from the top.
    private func red(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[0]
    }
}
