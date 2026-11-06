import CoreGraphics
import CoreImage
import Foundation

public enum GradeEngine {
    /// Same pixel size as source. Neutral settings with showClipping false must return the source unchanged (same CGImage is fine).
    public static func render(source: CGImage, settings: GradeSettings, showClipping: Bool, cropRect: Bool = true, grainScale: CGFloat = 1) -> CGImage {
        if settings.isNeutral && !showClipping {
            return source
        }

        var image = applyGeometry(CIImage(cgImage: source), edit: settings.crop, cropRect: cropRect)
        let extent = image.extent

        if settings.temperature != 0 || settings.tint != 0 {
            if let filtered = applyWhiteBalance(image, settings: settings) {
                image = filtered
            }
        }

        if settings.needsColorCube {
            if let filtered = applyColorCube(image, settings: settings) {
                image = filtered
            }
        }

        if settings.clarity != 0 {
            if let filtered = applyClarity(image, amount: settings.clarity) {
                image = filtered.cropped(to: extent)
            }
        }

        if settings.definition != 0 {
            if let filtered = applyDefinition(image, amount: settings.definition) {
                image = filtered.cropped(to: extent)
            }
        }

        if settings.filter != .original, settings.filterStrength > 0 {
            if let filtered = applyPhotoFilter(image, filter: settings.filter, strength: settings.filterStrength) {
                image = filtered.cropped(to: extent)
            }
        }

        if settings.noiseReduction > 0 {
            if let filtered = applyNoiseReduction(image, amount: settings.noiseReduction) {
                image = filtered.cropped(to: extent)
            }
        }

        if settings.sharpen > 0 {
            if let filtered = applySharpen(image, amount: settings.sharpen) {
                image = filtered.cropped(to: extent)
            }
        }

        if settings.vignette > 0 {
            if let filtered = applyVignette(image, amount: settings.vignette) {
                image = filtered.cropped(to: extent)
            }
        }

        if settings.grainShadows > 0 || settings.grainMidtones > 0 || settings.grainHighlights > 0 {
            if let filtered = applyGrain(
                image,
                shadows: settings.grainShadows,
                midtones: settings.grainMidtones,
                highlights: settings.grainHighlights,
                extent: extent,
                grainScale: grainScale
            ) {
                image = filtered.cropped(to: extent)
            }
        }

        if showClipping {
            if let filtered = applyClippingOverlay(image) {
                image = filtered.cropped(to: extent)
            }
        }

        image = filled(image, extent: extent)
        if let cg = sharedContext.createCGImage(image, from: extent) {
            return cg
        }
        return source
    }

    /// Oriented bitmap. `cropRect` false keeps the full frame so a crop overlay can sit on it.
    public static func applyingGeometry(to source: CGImage, edit: CropEdit, cropRect: Bool) -> CGImage {
        let image = applyGeometry(CIImage(cgImage: source), edit: edit, cropRect: cropRect)
        let output = cropRect ? filled(image, extent: image.extent) : image
        return sharedContext.createCGImage(output, from: output.extent) ?? source
    }

    private static func applyGeometry(_ image: CIImage, edit: CropEdit, cropRect: Bool) -> CIImage {
        var output = shiftToOrigin(image)
        let turns = edit.quarterTurns % 4
        for _ in 0..<turns {
            output = shiftToOrigin(output.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)))
        }
        if edit.mirrored {
            output = shiftToOrigin(output.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        if abs(edit.straighten) > 1e-9 {
            let radians = CGFloat(edit.straighten) * .pi / 180
            output = shiftToOrigin(output.transformed(by: CGAffineTransform(rotationAngle: radians)))
        }
        guard cropRect else { return output }
        let rect = edgeSafeCrop(of: output, edit: edit)
        return shiftToOrigin(output.cropped(to: rect))
    }

    /// Whole pixels that sit fully inside the photo. A fractional crop edge is a blend
    /// with the empty outside, and that blend becomes a thin light line once the file is opaque.
    private static func edgeSafeCrop(of image: CIImage, edit: CropEdit) -> CGRect {
        let bounds = image.extent
        let size = bounds.size
        let crop = CropGeometry.orientedCrop(edit: edit, orientedSize: size)
        var rect = CGRect(
            x: bounds.minX + crop.minX,
            y: bounds.minY + (size.height - crop.maxY),
            width: crop.width,
            height: crop.height
        ).intersection(bounds)
        if abs(edit.straighten) > 1e-9 {
            let inset = rect.insetBy(dx: 1, dy: 1)
            if inset.width >= 1, inset.height >= 1 {
                rect = inset
            }
        }
        var minX = ceil(rect.minX - 0.001)
        var minY = ceil(rect.minY - 0.001)
        var maxX = floor(rect.maxX + 0.001)
        var maxY = floor(rect.maxY + 0.001)
        if maxX - minX < 1 {
            minX = floor(rect.minX)
            maxX = min(minX + 1, bounds.maxX)
        }
        if maxY - minY < 1 {
            minY = floor(rect.minY)
            maxY = min(minY + 1, bounds.maxY)
        }
        let snapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
        if snapped.width < 1 || snapped.height < 1 {
            return bounds
        }
        return snapped
    }

    private static func shiftToOrigin(_ image: CIImage) -> CIImage {
        let extent = image.extent
        if abs(extent.minX) < 0.01 && abs(extent.minY) < 0.01 { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// Uses the alpha of a cutout as a mask over an opaque graded image.
    public static func applyingMask(from cutout: CGImage, to graded: CGImage) -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: CGFloat(graded.width), height: CGFloat(graded.height))
        let base = CIImage(cgImage: graded)
        var maskImage = CIImage(cgImage: cutout)
        let scaleX = extent.width / max(maskImage.extent.width, 1)
        let scaleY = extent.height / max(maskImage.extent.height, 1)
        if abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 {
            maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        let alpha = maskImage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let blended = base
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: alpha
            ])
            .cropped(to: extent)
        return sharedContext.createCGImage(blended, from: extent) ?? graded
    }

    // MARK: - Shared context

    private static let sharedContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: srgb,
            .outputColorSpace: srgb
        ])
    }()

    private static let cubeLock = NSLock()
    private static var cubeCache: [CubeCacheKey: Data] = [:]
    private static let cubeDimension = 33

    private static var grainTile: CGImage?
    private static let grainLock = NSLock()

    // MARK: - White balance

    private static func applyWhiteBalance(_ image: CIImage, settings: GradeSettings) -> CIImage? {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        // Positive temperature lowers target Kelvin so the image warms (R rises vs B).
        filter.setValue(
            CIVector(x: 6500 - settings.temperature * 32, y: settings.tint * 0.5),
            forKey: "inputTargetNeutral"
        )
        return filter.outputImage
    }

    // MARK: - Color cube

    private struct CubeCacheKey: Hashable {
        let token: String

        init(_ s: GradeSettings) {
            // Encode only point-op fields so clarity/sharpen/etc. do not bust the cache.
            var parts: [String] = [
                "e:\(s.exposure)",
                "br:\(s.brightness)",
                "c:\(s.contrast)",
                "hi:\(s.highlights)",
                "sh:\(s.shadows)",
                "w:\(s.whites)",
                "bl:\(s.blacks)",
                "sa:\(s.saturation)",
                "v:\(s.vibrance)",
                "f:\(s.fade)"
            ]
            for (i, adj) in s.hsl.enumerated() {
                parts.append("hsl\(i):\(adj.hue),\(adj.saturation),\(adj.luminance)")
            }
            func curveToken(_ name: String, _ curve: ToneCurve) -> String {
                let pts = curve.points.map { "\($0.x),\($0.y)" }.joined(separator: ";")
                return "\(name):\(pts)"
            }
            parts.append(curveToken("rgb", s.curves.rgb))
            parts.append(curveToken("r", s.curves.red))
            parts.append(curveToken("g", s.curves.green))
            parts.append(curveToken("b", s.curves.blue))
            token = parts.joined(separator: "|")
        }
    }

    private static func applyColorCube(_ image: CIImage, settings: GradeSettings) -> CIImage? {
        let key = CubeCacheKey(settings)
        let data: Data = {
            cubeLock.lock()
            defer { cubeLock.unlock() }
            if let cached = cubeCache[key] {
                return cached
            }
            let built = buildColorCube(settings)
            cubeCache[key] = built
            return built
        }()

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cubeDimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        return filter.outputImage
    }

    private static func buildColorCube(_ settings: GradeSettings) -> Data {
        let dim = cubeDimension
        let count = dim * dim * dim * 4
        var floats = [Float](repeating: 0, count: count)

        let rgbLUT = CurveMath.samples(points: settings.curves.rgb.points, count: 256)
        let rLUT = CurveMath.samples(points: settings.curves.red.points, count: 256)
        let gLUT = CurveMath.samples(points: settings.curves.green.points, count: 256)
        let bLUT = CurveMath.samples(points: settings.curves.blue.points, count: 256)

        let hslCenters: [Double] = [0, 30, 55, 120, 180, 230, 275, 315]
        let hslActive = settings.hsl.enumerated().compactMap { index, adj -> (Double, HSLAdjustment)? in
            guard !adj.isZero, index < hslCenters.count else { return nil }
            return (hslCenters[index], adj)
        }

        let exposureMul = Float(pow(2.0, settings.exposure))
        let brightnessAdd = Float(settings.brightness / 100.0 * 0.22)
        let contrastScale = Float(1.0 + settings.contrast / 100.0 * 0.75)
        let blacksAmt = Float(settings.blacks / 100.0)
        let whitesAmt = Float(settings.whites / 100.0)
        let shadowsAmt = Float(settings.shadows / 100.0)
        let highlightsAmt = Float(settings.highlights / 100.0)
        let satFactor = Float(1.0 + settings.saturation / 100.0)
        let vibranceAmt = Float(settings.vibrance / 100.0)
        let fadeT = Float(settings.fade / 100.0)

        var index = 0
        for bi in 0..<dim {
            let b0 = Float(bi) / Float(dim - 1)
            for gi in 0..<dim {
                let g0 = Float(gi) / Float(dim - 1)
                for ri in 0..<dim {
                    let r0 = Float(ri) / Float(dim - 1)
                    var r = r0
                    var g = g0
                    var b = b0

                    // Exposure + soft knee
                    r *= exposureMul
                    g *= exposureMul
                    b *= exposureMul
                    r = softKnee(r)
                    g = softKnee(g)
                    b = softKnee(b)

                    // Brightness
                    r += brightnessAdd
                    g += brightnessAdd
                    b += brightnessAdd

                    // Contrast around 0.5
                    r = 0.5 + (r - 0.5) * contrastScale
                    g = 0.5 + (g - 0.5) * contrastScale
                    b = 0.5 + (b - 0.5) * contrastScale

                    // Blacks / Whites
                    if blacksAmt != 0 {
                        let wr = pow(max(1 - r, 0), 3)
                        let wg = pow(max(1 - g, 0), 3)
                        let wb = pow(max(1 - b, 0), 3)
                        r += blacksAmt * 0.28 * wr
                        g += blacksAmt * 0.28 * wg
                        b += blacksAmt * 0.28 * wb
                    }
                    if whitesAmt != 0 {
                        let wr = pow(max(r, 0), 3)
                        let wg = pow(max(g, 0), 3)
                        let wb = pow(max(b, 0), 3)
                        r += whitesAmt * 0.28 * wr
                        g += whitesAmt * 0.28 * wg
                        b += whitesAmt * 0.28 * wb
                    }

                    // Shadows / Highlights (lower / upper half)
                    if shadowsAmt != 0 {
                        let wr = shadowWeight(r)
                        let wg = shadowWeight(g)
                        let wb = shadowWeight(b)
                        r += shadowsAmt * 0.32 * wr
                        g += shadowsAmt * 0.32 * wg
                        b += shadowsAmt * 0.32 * wb
                    }
                    if highlightsAmt != 0 {
                        let wr = highlightWeight(r)
                        let wg = highlightWeight(g)
                        let wb = highlightWeight(b)
                        r += highlightsAmt * 0.32 * wr
                        g += highlightsAmt * 0.32 * wg
                        b += highlightsAmt * 0.32 * wb
                    }

                    // Master RGB curve then per-channel
                    r = applyLUT(rgbLUT, r)
                    g = applyLUT(rgbLUT, g)
                    b = applyLUT(rgbLUT, b)
                    r = applyLUT(rLUT, r)
                    g = applyLUT(gLUT, g)
                    b = applyLUT(bLUT, b)

                    // Vibrance then saturation
                    if vibranceAmt != 0 {
                        applyVibrance(&r, &g, &b, amount: vibranceAmt)
                    }
                    if satFactor != 1 {
                        applySaturation(&r, &g, &b, factor: satFactor)
                    }

                    // HSL bands
                    if !hslActive.isEmpty {
                        applyHSL(&r, &g, &b, bands: hslActive)
                    }

                    // Fade
                    if fadeT > 0 {
                        applyFade(&r, &g, &b, t: fadeT)
                    }

                    floats[index] = clamp01(r)
                    floats[index + 1] = clamp01(g)
                    floats[index + 2] = clamp01(b)
                    floats[index + 3] = 1
                    index += 4
                }
            }
        }

        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func softKnee(_ v: Float) -> Float {
        let knee: Float = 0.8
        if v <= knee { return v }
        let over = v - knee
        return knee + over / (1 + over * 2.2)
    }

    private static func shadowWeight(_ x: Float) -> Float {
        let t = clamp01(1 - x)
        return t * t
    }

    private static func highlightWeight(_ x: Float) -> Float {
        let t = clamp01(x)
        return t * t
    }

    private static func applyLUT(_ lut: [Double], _ x: Float) -> Float {
        let clamped = clamp01(x)
        let scaled = clamped * Float(lut.count - 1)
        let i0 = Int(scaled)
        let i1 = min(i0 + 1, lut.count - 1)
        let frac = scaled - Float(i0)
        return Float(lut[i0]) * (1 - frac) + Float(lut[i1]) * frac
    }

    private static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func applySaturation(_ r: inout Float, _ g: inout Float, _ b: inout Float, factor: Float) {
        let y = luma(r, g, b)
        r = y + (r - y) * factor
        g = y + (g - y) * factor
        b = y + (b - y) * factor
    }

    private static func applyVibrance(_ r: inout Float, _ g: inout Float, _ b: inout Float, amount: Float) {
        let maxc = max(r, max(g, b))
        let minc = min(r, min(g, b))
        let sat = maxc > 1e-5 ? (maxc - minc) / maxc : 0
        // Stronger on low-saturation pixels
        let factor = 1 + amount * 0.85 * (1 - sat)
        applySaturation(&r, &g, &b, factor: factor)
    }

    private static func applyFade(_ r: inout Float, _ g: inout Float, _ b: inout Float, t: Float) {
        // Lift blacks, compress contrast, slight desat
        r = r * (1 - t * 0.38) + t * 0.14
        g = g * (1 - t * 0.38) + t * 0.14
        b = b * (1 - t * 0.38) + t * 0.14
        applySaturation(&r, &g, &b, factor: 1 - t * 0.22)
    }

    private static func applyHSL(
        _ r: inout Float,
        _ g: inout Float,
        _ b: inout Float,
        bands: [(Double, HSLAdjustment)]
    ) {
        var (h, s, l) = rgbToHSL(r, g, b)
        let hueDeg = Double(h) * 360

        for (center, adj) in bands {
            let weight = bandWeight(hueDeg: hueDeg, center: center)
            guard weight > 1e-5 else { continue }
            let hueShift = (adj.hue / 100.0) * 40.0 * weight
            h = Float((Double(h) * 360 + hueShift).truncatingRemainder(dividingBy: 360))
            if h < 0 { h += 360 }
            h /= 360

            let satMul = 1 + Float(adj.saturation / 100.0) * Float(weight)
            s = clamp01(s * satMul)

            let lumShift = Float(adj.luminance / 100.0) * 0.35 * Float(weight)
            l = clamp01(l + lumShift)

            // Refresh hue degrees after shift for next band
            // (use updated h)
        }

        let rgb = hslToRGB(h, s, l)
        r = rgb.0
        g = rgb.1
        b = rgb.2
    }

    /// Smooth falloff around a hue center in degrees. Red wraps around 0/360.
    private static func bandWeight(hueDeg: Double, center: Double) -> Double {
        var d = abs(hueDeg - center)
        if d > 180 { d = 360 - d }
        // Half-width ~35° with smooth cosine falloff
        let half: Double = 35
        if d >= half { return 0 }
        let t = d / half
        return 0.5 * (1 + cos(.pi * t))
    }

    private static func rgbToHSL(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let maxc = max(r, max(g, b))
        let minc = min(r, min(g, b))
        let l = (maxc + minc) * 0.5
        let delta = maxc - minc
        guard delta > 1e-6 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxc - minc) : delta / (maxc + minc)
        var h: Float
        if maxc == r {
            h = (g - b) / delta + (g < b ? 6 : 0)
        } else if maxc == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h /= 6
        return (h, s, l)
    }

    private static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> (Float, Float, Float) {
        if s < 1e-6 {
            return (l, l, l)
        }
        func hue2rgb(_ p: Float, _ q: Float, _ tIn: Float) -> Float {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let r = hue2rgb(p, q, h + 1 / 3)
        let g = hue2rgb(p, q, h)
        let b = hue2rgb(p, q, h - 1 / 3)
        return (r, g, b)
    }

    private static func clamp01(_ v: Float) -> Float {
        min(max(v, 0), 1)
    }

    // MARK: - Spatial / style filters

    /// Repeat the edge pixel so a blur or sharpen does not sample the empty outside.
    private static func clamped(_ image: CIImage) -> CIImage {
        image.clampedToExtent()
    }

    /// Cover any leftover transparent edge with the photo's own edge color, not white.
    private static func filled(_ image: CIImage, extent: CGRect) -> CIImage {
        image.composited(over: image.clampedToExtent()).cropped(to: extent)
    }

    private static func applyClarity(_ image: CIImage, amount: Double) -> CIImage? {
        let extent = image.extent
        let source = clamped(image)
        if amount > 0 {
            guard let filter = CIFilter(name: "CIUnsharpMask") else { return nil }
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(30.0, forKey: kCIInputRadiusKey)
            filter.setValue(amount / 100.0 * 0.6, forKey: kCIInputIntensityKey)
            return filter.outputImage?.cropped(to: extent)
        } else {
            let t = abs(amount) / 100.0
            guard t > 0, let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
            blur.setValue(source, forKey: kCIInputImageKey)
            blur.setValue(4.0 + t * 8.0, forKey: kCIInputRadiusKey)
            guard let blurred = blur.outputImage else { return nil }
            return image.applyingFilter(
                "CIDissolveTransition",
                parameters: [
                    kCIInputTargetImageKey: blurred,
                    kCIInputTimeKey: t * 0.85
                ]
            ).cropped(to: extent)
        }
    }

    private static let definitionKernel: CIKernel? = {
        let source = """
        kernel vec4 definition(sampler img, sampler soft, float amount) {
            vec2 p = destCoord();
            vec4 s = sample(img, samplerTransform(img, p));
            vec4 b = sample(soft, samplerTransform(soft, p));
            float y = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            float mid = smoothstep(0.05, 0.28, y) * (1.0 - smoothstep(0.72, 0.96, y));
            vec3 c = clamp(s.rgb + (s.rgb - b.rgb) * amount * mid, 0.0, 1.0);
            return vec4(c, s.a);
        }
        """
        return CIKernel(source: source)
    }()

    /// Local contrast in the middle tones. Flat areas, deep shadows, and bright highlights stay put.
    private static func applyDefinition(_ image: CIImage, amount: Double) -> CIImage? {
        guard let kernel = definitionKernel else { return nil }
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        let radius = max(longSide * 0.01, 2)
        let source = clamped(image)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(source, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let soft = blur.outputImage else { return nil }
        let scaled = amount >= 0 ? amount / 100.0 * 1.45 : amount / 100.0 * 0.8
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [source, soft, scaled]
        )?.cropped(to: extent)
    }

    private struct PhotoLook {
        var brightness: CGFloat = 0
        var contrast: CGFloat = 1
        var saturation: CGFloat = 1
        var kelvin: CGFloat?
        var tint: CGFloat = 0
        var highlight: CGFloat?
        var shadow: CGFloat?
        var vignette: CGFloat = 0

        static func recipe(_ filter: PhotoFilter) -> PhotoLook? {
            switch filter {
            case .original:
                return nil
            case .vivid:
                return PhotoLook(brightness: 0.015, contrast: 1.1, saturation: 1.45)
            case .vividWarm:
                return PhotoLook(brightness: 0.02, contrast: 1.1, saturation: 1.42, kelvin: 5000)
            case .vividCool:
                return PhotoLook(brightness: 0.01, contrast: 1.1, saturation: 1.4, kelvin: 8200)
            case .dramatic:
                return PhotoLook(brightness: -0.03, contrast: 1.28, saturation: 0.72, highlight: 0.75, shadow: -0.2, vignette: 1.1)
            case .dramaticWarm:
                return PhotoLook(brightness: -0.02, contrast: 1.26, saturation: 0.78, kelvin: 4800, highlight: 0.78, shadow: -0.15, vignette: 1.05)
            case .dramaticCool:
                return PhotoLook(brightness: -0.03, contrast: 1.28, saturation: 0.7, kelvin: 8800, highlight: 0.72, shadow: -0.22, vignette: 1.15)
            case .mono:
                return PhotoLook(contrast: 1.08, saturation: 0)
            case .silvertone:
                return PhotoLook(brightness: 0.04, contrast: 0.9, saturation: 0, kelvin: 5600, tint: 6, shadow: 0.45, vignette: 0.35)
            case .noir:
                return PhotoLook(brightness: -0.02, contrast: 1.45, saturation: 0, highlight: 0.8, shadow: -0.45, vignette: 1.5)
            }
        }
    }

    /// iOS Photos looks. Strength dissolves the full look back toward the graded photo.
    private static func applyPhotoFilter(_ image: CIImage, filter: PhotoFilter, strength: Double) -> CIImage? {
        let amount = min(max(strength / 100, 0), 1)
        guard amount > 0.0001, let look = photoLook(image, filter) else { return nil }
        let extent = image.extent
        let full = look.cropped(to: extent)
        if amount > 0.999 { return full }
        return image.applyingFilter(
            "CIDissolveTransition",
            parameters: [
                kCIInputTargetImageKey: full,
                kCIInputTimeKey: amount
            ]
        ).cropped(to: extent)
    }

    private static func photoLook(_ image: CIImage, _ filter: PhotoFilter) -> CIImage? {
        guard let recipe = PhotoLook.recipe(filter) else { return nil }
        let extent = image.extent
        var output = clamped(image)
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(recipe.saturation, forKey: kCIInputSaturationKey)
            controls.setValue(recipe.contrast, forKey: kCIInputContrastKey)
            controls.setValue(recipe.brightness, forKey: kCIInputBrightnessKey)
            if let next = controls.outputImage { output = next }
        }
        if let kelvin = recipe.kelvin, let balance = CIFilter(name: "CITemperatureAndTint") {
            balance.setValue(output, forKey: kCIInputImageKey)
            balance.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            balance.setValue(CIVector(x: kelvin, y: recipe.tint), forKey: "inputTargetNeutral")
            if let next = balance.outputImage { output = next }
        }
        if recipe.highlight != nil || recipe.shadow != nil, let tone = CIFilter(name: "CIHighlightShadowAdjust") {
            tone.setValue(output, forKey: kCIInputImageKey)
            if let highlight = recipe.highlight {
                tone.setValue(highlight, forKey: "inputHighlightAmount")
            }
            if let shadow = recipe.shadow {
                tone.setValue(shadow, forKey: "inputShadowAmount")
            }
            if let next = tone.outputImage { output = next }
        }
        if recipe.vignette > 0, let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(output, forKey: kCIInputImageKey)
            vignette.setValue(recipe.vignette, forKey: kCIInputIntensityKey)
            vignette.setValue(1.6, forKey: kCIInputRadiusKey)
            if let next = vignette.outputImage { output = next }
        }
        return output.cropped(to: extent)
    }

    private static func applyNoiseReduction(_ image: CIImage, amount: Double) -> CIImage? {
        guard let filter = CIFilter(name: "CINoiseReduction") else { return nil }
        filter.setValue(clamped(image), forKey: kCIInputImageKey)
        filter.setValue(amount / 100.0 * 0.07, forKey: "inputNoiseLevel")
        filter.setValue(0.02, forKey: "inputSharpness")
        return filter.outputImage?.cropped(to: image.extent)
    }

    private static func applySharpen(_ image: CIImage, amount: Double) -> CIImage? {
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return nil }
        filter.setValue(clamped(image), forKey: kCIInputImageKey)
        filter.setValue(amount / 100.0 * 1.3, forKey: kCIInputSharpnessKey)
        filter.setValue(1.5, forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: image.extent)
    }

    private static func applyVignette(_ image: CIImage, amount: Double) -> CIImage? {
        guard let filter = CIFilter(name: "CIVignette") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(amount / 100.0 * 2.2, forKey: kCIInputIntensityKey)
        filter.setValue(1.5, forKey: kCIInputRadiusKey)
        return filter.outputImage
    }

    private static let grainKernel: CIKernel? = {
        let source = """
        kernel vec4 tonalGrain(sampler img, sampler noise, float sh, float mid, float hi) {
            vec2 p = destCoord();
            vec4 s = sample(img, samplerTransform(img, p));
            vec4 n = sample(noise, samplerTransform(noise, p));
            float y = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            float shadowW = 1.0 - smoothstep(0.08, 0.58, y);
            float highW = smoothstep(0.42, 0.92, y);
            float midW = 1.0 - smoothstep(0.10, 0.46, abs(y - 0.5));
            float w = clamp(shadowW * sh + midW * mid + highW * hi, 0.0, 1.0);
            vec3 c = clamp(s.rgb + (n.r - 0.5) * w * 1.05, 0.0, 1.0);
            return vec4(c, s.a);
        }
        """
        return CIKernel(source: source)
    }()

    /// Slider 0...100 stays put. The power stays quiet at the bottom and climbs
    /// toward the top. The kernel mix (1.05) is the strength at the top.
    private static func grainResponse(_ value: Double) -> Double {
        let t = min(max(value / 100.0, 0), 1)
        return pow(t, 1.8)
    }

    private static func applyGrain(
        _ image: CIImage,
        shadows: Double,
        midtones: Double,
        highlights: Double,
        extent: CGRect,
        grainScale: CGFloat
    ) -> CIImage? {
        let sh = grainResponse(shadows)
        let mid = grainResponse(midtones)
        let hi = grainResponse(highlights)
        guard sh > 0 || mid > 0 || hi > 0, let kernel = grainKernel else { return nil }
        let noise = grainField(scale: max(grainScale, 1))
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [image, noise, sh, mid, hi]
        )
    }

    /// One noise texel is one original-image pixel. A smaller render averages that
    /// tile down so the preview matches the full-resolution file at the same size.
    private static func grainField(scale: CGFloat) -> CIImage {
        guard let tile = grainTileImage() else {
            return CIImage(color: .gray)
        }
        let image: CGImage
        if scale <= 1.001 {
            image = tile
        } else {
            let side = max(Int((CGFloat(tile.width) / scale).rounded()), 1)
            image = downsample(tile, to: side) ?? tile
        }
        return CIImage(cgImage: image).applyingFilter("CIAffineTile", parameters: [:])
    }

    private static func grainTileImage() -> CGImage? {
        grainLock.lock()
        defer { grainLock.unlock() }
        if let cached = grainTile {
            return cached
        }
        let size = 512
        let fixed = CGRect(x: 0, y: 0, width: size, height: size)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        sharedContext.render(
            random.cropped(to: fixed),
            toBitmap: &bytes,
            rowBytes: size * 4,
            bounds: fixed,
            format: .RGBA8,
            colorSpace: cs
        )
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: size * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        let contrasted = CIImage(cgImage: cg).applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.35
            ]
        )
        guard let baked = sharedContext.createCGImage(contrasted, from: fixed) else { return nil }
        grainTile = baked
        return baked
    }

    private static func downsample(_ image: CGImage, to side: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    // MARK: - Clipping overlay

    private static let clippingKernel: CIColorKernel? = {
        let source = """
        kernel vec4 clipWarn(__sample s) {
            float luma = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            vec3 c = s.rgb;
            if (luma > 0.975) {
                c = mix(c, vec3(1.0, 0.18, 0.22), 0.6);
            } else if (luma < 0.025) {
                c = mix(c, vec3(0.2, 0.45, 1.0), 0.6);
            }
            return vec4(c, s.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    private static func applyClippingOverlay(_ image: CIImage) -> CIImage? {
        if let kernel = clippingKernel {
            return kernel.apply(extent: image.extent, arguments: [image])
        }
        return bitmapClippingOverlay(image)
    }

    private static func bitmapClippingOverlay(_ image: CIImage) -> CIImage? {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let rowBytes = width * 4
        sharedContext.render(
            image,
            toBitmap: &pixels,
            rowBytes: rowBytes,
            bounds: extent,
            format: .RGBA8,
            colorSpace: cs
        )
        for i in 0..<(width * height) {
            let o = i * 4
            let r = Float(pixels[o]) / 255
            let g = Float(pixels[o + 1]) / 255
            let b = Float(pixels[o + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if y > 0.975 {
                pixels[o] = UInt8(min(255, Int((r * 0.4 + 1.0 * 0.6) * 255)))
                pixels[o + 1] = UInt8(min(255, Int((g * 0.4 + 0.18 * 0.6) * 255)))
                pixels[o + 2] = UInt8(min(255, Int((b * 0.4 + 0.22 * 0.6) * 255)))
            } else if y < 0.025 {
                pixels[o] = UInt8(min(255, Int((r * 0.4 + 0.2 * 0.6) * 255)))
                pixels[o + 1] = UInt8(min(255, Int((g * 0.4 + 0.45 * 0.6) * 255)))
                pixels[o + 2] = UInt8(min(255, Int((b * 0.4 + 1.0 * 0.6) * 255)))
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            translationX: extent.origin.x,
            y: extent.origin.y
        ))
    }
}
