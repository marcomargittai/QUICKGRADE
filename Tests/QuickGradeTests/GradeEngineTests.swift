import CoreGraphics
import XCTest
@testable import QuickGradeCore

final class GradeEngineTests: XCTestCase {
    func testNeutralRenderEqualsSourceBytes() {
        let source = makeSolid(r: 120, g: 140, b: 160, width: 8, height: 8)
        let out = GradeEngine.render(source: source, settings: .neutral, showClipping: false)
        XCTAssertEqual(out.width, source.width)
        XCTAssertEqual(out.height, source.height)
        let a = rgbaBytes(source)
        let b = rgbaBytes(out)
        XCTAssertEqual(a, b)
    }

    func testExposurePlusOneRaisesMidGrayGreen() {
        let source = makeSolid(r: 128, g: 128, b: 128, width: 4, height: 4)
        var settings = GradeSettings.neutral
        settings.exposure = 1
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let src = averageRGB(source)
        let dst = averageRGB(out)
        XCTAssertGreaterThan(dst.g, src.g + 8, "exposure +1 should raise mid gray")
    }

    func testSaturationMinus100OnRedPullsGBTowardR() {
        let source = makeSolid(r: 220, g: 20, b: 20, width: 4, height: 4)
        var settings = GradeSettings.neutral
        settings.saturation = -100
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let src = averageRGB(source)
        let dst = averageRGB(out)
        let srcSpread = abs(src.r - src.g) + abs(src.r - src.b)
        let dstSpread = abs(dst.r - dst.g) + abs(dst.r - dst.b)
        XCTAssertLessThan(dstSpread, srcSpread * 0.25, "sat -100 should collapse toward gray/luma")
        XCTAssertGreaterThan(dst.g, src.g + 20)
        XCTAssertGreaterThan(dst.b, src.b + 20)
    }

    func testHighlightsMinus100DarkensNearWhite() {
        let source = makeSolid(r: 245, g: 245, b: 245, width: 4, height: 4)
        var settings = GradeSettings.neutral
        settings.highlights = -100
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let src = averageRGB(source)
        let dst = averageRGB(out)
        XCTAssertLessThan(dst.g, src.g - 8, "highlights -100 should darken near-white")
    }

    func testBlacksPlus100LiftsNearBlack() {
        let source = makeSolid(r: 12, g: 12, b: 12, width: 4, height: 4)
        var settings = GradeSettings.neutral
        settings.blacks = 100
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let src = averageRGB(source)
        let dst = averageRGB(out)
        XCTAssertGreaterThan(dst.g, src.g + 8, "blacks +100 should lift near-black")
    }

    func testTemperaturePlus100WarmsMidGray() {
        let source = makeSolid(r: 128, g: 128, b: 128, width: 8, height: 8)
        var settings = GradeSettings.neutral
        settings.temperature = 100
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let dst = averageRGB(out)
        XCTAssertGreaterThan(dst.r, dst.b + 4, "temperature +100 must make R > B on mid gray")
    }

    func testGradientRendersWithoutCrash() {
        let source = makeGradient(width: 16, height: 4)
        let out = GradeEngine.render(source: source, settings: .neutral, showClipping: false)
        XCTAssertEqual(out.width, source.width)
        // left should stay near black, right near white under neutral
        let bytes = rgbaBytes(out)
        XCTAssertLessThan(bytes[0], 20)
        let last = (3 * 16 + 15) * 4
        XCTAssertGreaterThan(bytes[last], 230)
    }

    func testCurvePinnedToQuarter() {
        let source = makeSolid(r: 180, g: 180, b: 180, width: 4, height: 4)
        var settings = GradeSettings.neutral
        settings.curves.rgb = ToneCurve(points: [
            CurvePoint(x: 0, y: 0.25),
            CurvePoint(x: 1, y: 0.25)
        ])
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let dst = averageRGB(out)
        let expected: CGFloat = 0.25 * 255
        XCTAssertEqual(dst.r, expected, accuracy: 18)
        XCTAssertEqual(dst.g, expected, accuracy: 18)
        XCTAssertEqual(dst.b, expected, accuracy: 18)
    }

    // MARK: - Helpers

    func testShadowGrainMovesDarksAndLeavesLights() {
        let source = makeGradient(width: 48, height: 8)
        var settings = GradeSettings.neutral
        settings.grainShadows = 100
        let out = GradeEngine.render(source: source, settings: settings, showClipping: false)
        let src = rgbaBytes(source)
        let dst = rgbaBytes(out)
        let width = 48
        func delta(_ x0: Int, _ x1: Int) -> Int {
            var sum = 0
            var count = 0
            for y in 0..<8 {
                for x in x0..<x1 {
                    let o = (y * width + x) * 4
                    sum += abs(Int(dst[o]) - Int(src[o]))
                    count += 1
                }
            }
            return count == 0 ? 0 : sum / count
        }
        let dark = delta(0, 8)
        let light = delta(40, 48)
        XCTAssertGreaterThan(dark, 4, "grain in dark tones should move near-black pixels")
        XCTAssertLessThan(light, 2, "light pixels should stay put when only dark grain is up")
    }

    func testPreviewGrainIsQuieterThanFullResolution() {
        let source = makeGradient(width: 64, height: 16)
        var settings = GradeSettings.neutral
        settings.grainMidtones = 100
        let full = GradeEngine.render(source: source, settings: settings, showClipping: false, grainScale: 1)
        let preview = GradeEngine.render(source: source, settings: settings, showClipping: false, grainScale: 4)
        func energy(_ image: CGImage) -> Int {
            let src = rgbaBytes(source)
            let dst = rgbaBytes(image)
            var sum = 0
            let count = min(src.count, dst.count) / 4
            for i in 0..<count {
                sum += abs(Int(dst[i * 4]) - Int(src[i * 4]))
            }
            return sum
        }
        XCTAssertGreaterThan(energy(full), energy(preview))
    }

    private func makeSolid(r: UInt8, g: UInt8, b: UInt8, width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            pixels[o] = r
            pixels[o + 1] = g
            pixels[o + 2] = b
            pixels[o + 3] = 255
        }
        return makeImage(pixels: pixels, width: width, height: height)
    }

    private func makeGradient(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(Double(x) / Double(max(width - 1, 1)) * 255)
                let o = (y * width + x) * 4
                pixels[o] = v
                pixels[o + 1] = v
                pixels[o + 2] = v
                pixels[o + 3] = 255
            }
        }
        return makeImage(pixels: pixels, width: width, height: height)
    }

    func testDefinitionPopsMidtoneEdgesAndLeavesFlatTones() {
        let flat = makeSolid(r: 80, g: 80, b: 80, width: 48, height: 24)
        var defined = GradeSettings.neutral
        defined.definition = 100
        let definedFlat = GradeEngine.render(source: flat, settings: defined, showClipping: false)
        let flatBytes = rgbaBytes(definedFlat)
        let mid = (flatBytes.count / 4 / 2) * 4
        XCTAssertEqual(Int(flatBytes[mid]), 80, accuracy: 4)

        var contrasted = GradeSettings.neutral
        contrasted.contrast = 100
        let contrastFlat = GradeEngine.render(source: flat, settings: contrasted, showClipping: false)
        let contrastBytes = rgbaBytes(contrastFlat)
        XCTAssertLessThan(Int(contrastBytes[mid]), 65)

        let stepped = makeStep()
        var settings = GradeSettings.neutral
        settings.definition = 100
        let out = GradeEngine.render(source: stepped, settings: settings, showClipping: false)
        let src = rgbaBytes(stepped)
        let dst = rgbaBytes(out)
        let width = 240
        func gap(_ bytes: [UInt8], _ y: Int) -> Int {
            let left = (y * width + 118) * 4
            let right = (y * width + 122) * 4
            return Int(bytes[right]) - Int(bytes[left])
        }
        let midGain = gap(dst, 4) - gap(src, 4)
        let shadowGain = gap(dst, 20) - gap(src, 20)
        XCTAssertGreaterThan(midGain, 8, "midtone edges should open up")
        XCTAssertLessThan(shadowGain, midGain, "shadows should move less than midtones")
    }

    func testOlderGradesWithoutDefinitionStayNeutral() throws {
        let data = try JSONEncoder().encode(GradeSettings.neutral)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "definition")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: stripped)
        XCTAssertEqual(decoded.definition, 0)
        XCTAssertTrue(decoded.isNeutral)
        var edited = decoded
        edited.definition = 40
        XCTAssertFalse(edited.isPageNeutral(.light))
    }

    private func makeStep() -> CGImage {
        let width = 240
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let midtone = y < 16
                let left = x < width / 2
                let value: UInt8
                if midtone {
                    value = left ? 90 : 150
                } else {
                    value = left ? 10 : 30
                }
                let o = (y * width + x) * 4
                pixels[o] = value
                pixels[o + 1] = value
                pixels[o + 2] = value
                pixels[o + 3] = 255
            }
        }
        return makeImage(pixels: pixels, width: width, height: height)
    }

    func testIOSFiltersMatchTheirRoles() {
        let color = makeSolid(r: 200, g: 70, b: 60, width: 24, height: 16)
        let src = center(color)
        var vivid = GradeSettings.neutral
        vivid.filter = .vivid
        vivid.filterStrength = 100
        let vividPixel = center(GradeEngine.render(source: color, settings: vivid, showClipping: false))
        XCTAssertGreaterThan(vividPixel.r - vividPixel.g, src.r - src.g + 6, "vivid should push the red")

        var mono = GradeSettings.neutral
        mono.filter = .mono
        let monoPixel = center(GradeEngine.render(source: color, settings: mono, showClipping: false))
        XCTAssertEqual(monoPixel.r, monoPixel.g, accuracy: 2)
        XCTAssertEqual(monoPixel.g, monoPixel.b, accuracy: 2)

        let gray = makeSolid(r: 40, g: 40, b: 40, width: 24, height: 16)
        var noir = GradeSettings.neutral
        noir.filter = .noir
        let noirPixel = center(GradeEngine.render(source: gray, settings: noir, showClipping: false))
        let monoGray = center(GradeEngine.render(source: gray, settings: mono, showClipping: false))
        XCTAssertLessThan(noirPixel.r, monoGray.r - 4, "noir should crush the darks")

        let mid = makeSolid(r: 140, g: 140, b: 140, width: 24, height: 16)
        var warm = GradeSettings.neutral
        warm.filter = .dramaticWarm
        var cool = GradeSettings.neutral
        cool.filter = .dramaticCool
        let warmPixel = center(GradeEngine.render(source: mid, settings: warm, showClipping: false))
        let coolPixel = center(GradeEngine.render(source: mid, settings: cool, showClipping: false))
        XCTAssertGreaterThan(warmPixel.r, warmPixel.b + 2)
        XCTAssertGreaterThan(coolPixel.b, coolPixel.r + 2)

        var half = vivid
        half.filterStrength = 0
        let off = center(GradeEngine.render(source: color, settings: half, showClipping: false))
        XCTAssertEqual(off.r, src.r, accuracy: 2)
        XCTAssertEqual(off.g, src.g, accuracy: 2)
    }

    func testOlderGradesWithoutAFilterStayOriginal() throws {
        let data = try JSONEncoder().encode(GradeSettings.neutral)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "filter")
        object.removeValue(forKey: "filterStrength")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: stripped)
        XCTAssertEqual(decoded.filter, .original)
        XCTAssertEqual(decoded.filterStrength, 100)
        XCTAssertTrue(decoded.isNeutral)
        XCTAssertTrue(decoded.isPageNeutral(.filters))
    }

    private func center(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        let bytes = rgbaBytes(image)
        let o = ((image.height / 2) * image.width + image.width / 2) * 4
        return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
    }

    func testCroppedEdgesStayOpaque() {
        let source = makeSolid(r: 180, g: 40, b: 20, width: 80, height: 60)
        var settings = GradeSettings.neutral
        settings.crop = CropEdit(aspect: .free, rect: CGRect(x: 0.13, y: 0.17, width: 0.71, height: 0.63))
        assertPhotoEdges(GradeEngine.render(source: source, settings: settings, showClipping: false))

        settings.clarity = -80
        assertPhotoEdges(GradeEngine.render(source: source, settings: settings, showClipping: false))

        settings.clarity = 80
        assertPhotoEdges(GradeEngine.render(source: source, settings: settings, showClipping: false))

        settings.clarity = 0
        settings.crop = CropEdit(aspect: .free, rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), straighten: 8)
        assertPhotoEdges(GradeEngine.render(source: source, settings: settings, showClipping: false))
    }

    private func assertPhotoEdges(_ image: CGImage, file: StaticString = #file, line: UInt = #line) {
        let bytes = rgbaBytes(image)
        let w = image.width
        let h = image.height
        XCTAssertGreaterThan(w, 2, file: file, line: line)
        XCTAssertGreaterThan(h, 2, file: file, line: line)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                guard edge else { continue }
                let o = (y * w + x) * 4
                XCTAssertEqual(Int(bytes[o + 3]), 255, "edge alpha", file: file, line: line)
                XCTAssertGreaterThan(Int(bytes[o]), 140, "edge red", file: file, line: line)
                XCTAssertLessThan(Int(bytes[o + 1]), 80, "edge green", file: file, line: line)
                XCTAssertLessThan(Int(bytes[o + 2]), 60, "edge blue", file: file, line: line)
            }
        }
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

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width
        let h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    private func averageRGB(_ image: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let bytes = rgbaBytes(image)
        let count = image.width * image.height
        var r = 0, g = 0, b = 0
        for i in 0..<count {
            let o = i * 4
            r += Int(bytes[o])
            g += Int(bytes[o + 1])
            b += Int(bytes[o + 2])
        }
        let n = CGFloat(count)
        return (CGFloat(r) / n, CGFloat(g) / n, CGFloat(b) / n)
    }
}
