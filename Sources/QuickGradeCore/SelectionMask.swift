import CoreGraphics
import CoreImage
import Foundation
import Vision

public struct SelectionStroke: Codable, Equatable {
    public var points: [CGPoint]
    public var radius: CGFloat
    public var erases: Bool

    public init(points: [CGPoint], radius: CGFloat, erases: Bool) {
        self.points = points
        self.radius = min(max(radius, 0.002), 0.2)
        self.erases = erases
    }
}

public enum SelectionMaskError: Error, Equatable {
    case failed
}

public enum SelectionMask {
    /// Rasterize strokes into a grayscale mask, white = keep. Same pixel size as `size`. Erasers punch holes. Returns nil if every stroke is erased away.
    public static func strokeMask(strokes: [SelectionStroke], size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0, !strokes.isEmpty else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        var image: CGImage?
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(false)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            for stroke in strokes {
                guard !stroke.points.isEmpty else { continue }
                let gray: CGFloat = stroke.erases ? 0 : 1
                context.setFillColor(gray: gray, alpha: 1)
                context.setStrokeColor(gray: gray, alpha: 1)
                let radius = min(max(stroke.radius, 0.002), 0.2) * CGFloat(width)
                context.setLineWidth(radius * 2)
                let points = stroke.points.map { point in
                    CGPoint(
                        x: min(max(point.x, 0), 1) * CGFloat(width),
                        y: min(max(point.y, 0), 1) * CGFloat(height)
                    )
                }
                if points.count == 1, let point = points.first {
                    context.fillEllipse(in: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                } else {
                    context.beginPath()
                    context.move(to: points[0])
                    for point in points.dropFirst() {
                        context.addLine(to: point)
                    }
                    context.strokePath()
                }
            }
            image = context.makeImage()
        }
        guard let image, pixels.contains(where: { $0 > 8 }) else { return nil }
        return image
    }

    /// Smart cutout. `strokes` mark what should stay. `reach` is 0...1: low hugs the marker, high keeps the Vision instance the marker touches and grows past it. Feather the edge. Returns a CGImage with premultiplied alpha. Throws SelectionMaskError.failed if the stroke mask is empty or the result is empty.
    public static func cutout(source: CGImage, strokes: [SelectionStroke], reach: CGFloat = 0.55) throws -> CGImage {
        let size = CGSize(width: source.width, height: source.height)
        guard let stroke = strokeMask(strokes: strokes, size: size) else {
            throw SelectionMaskError.failed
        }
        let extent = CGRect(origin: .zero, size: size)
        let strokeImage = CIImage(cgImage: stroke)
        let clamped = min(max(reach, 0), 1)
        let shortSide = min(size.width, size.height)
        let strokeGrow = min(48, 2 + clamped * shortSide * 0.05)
        let dilated = dilate(strokeImage, radius: strokeGrow, extent: extent)

        let keep: CIImage
        if clamped < 0.12 {
            keep = dilated
        } else if let instances = instanceUnion(source: source, stroke: strokeImage, size: size) {
            if clamped >= 0.88 {
                let extra = min(28, (clamped - 0.88) / 0.12 * shortSide * 0.03)
                let grown = dilate(instances, radius: max(extra, 1), extent: extent)
                keep = grown
                    .applyingFilter("CIMaximumCompositing", parameters: [
                        kCIInputBackgroundImageKey: dilated
                    ])
                    .cropped(to: extent)
            } else {
                let t = (clamped - 0.12) / 0.76
                let gateRadius = min(80, strokeGrow + t * shortSide * 0.16)
                let gate = dilate(strokeImage, radius: gateRadius, extent: extent)
                let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
                let near = instances
                    .applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: black,
                        kCIInputMaskImageKey: gate
                    ])
                    .cropped(to: extent)
                keep = near
                    .applyingFilter("CIMaximumCompositing", parameters: [
                        kCIInputBackgroundImageKey: dilated
                    ])
                    .cropped(to: extent)
            }
        } else {
            keep = dilated
        }

        let feathered = feather(keep, radius: 0.8 + clamped * 2.0, extent: extent)
        return try apply(mask: feathered, to: source, extent: extent)
    }

    private static func instanceUnion(source: CGImage, stroke: CIImage, size: CGSize) -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let instances = observation.allInstances
        guard !instances.isEmpty else { return nil }

        var hits = IndexSet()
        for index in instances {
            guard let buffer = try? observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: index),
                from: handler
            ) else { continue }
            if overlaps(instance: buffer, stroke: stroke, size: size) {
                hits.insert(index)
            }
        }
        guard !hits.isEmpty else { return nil }
        guard let union = try? observation.generateScaledMaskForImage(forInstances: hits, from: handler) else {
            return nil
        }
        var image = CIImage(cvPixelBuffer: union)
        let scaleX = size.width / max(image.extent.width, 1)
        let scaleY = size.height / max(image.extent.height, 1)
        if scaleX != 1 || scaleY != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func overlaps(instance: CVPixelBuffer, stroke: CIImage, size: CGSize) -> Bool {
        let width = max(1, Int(size.width) / 4)
        let height = max(1, Int(size.height) / 4)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let gray = CGColorSpaceCreateDeviceGray()

        var instanceImage = CIImage(cvPixelBuffer: instance)
        let instanceScaleX = CGFloat(width) / max(instanceImage.extent.width, 1)
        let instanceScaleY = CGFloat(height) / max(instanceImage.extent.height, 1)
        instanceImage = instanceImage
            .transformed(by: CGAffineTransform(scaleX: instanceScaleX, y: instanceScaleY))
            .cropped(to: bounds)

        let strokeSmall = stroke
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / max(size.width, 1),
                y: CGFloat(height) / max(size.height, 1)
            ))
            .cropped(to: bounds)

        var strokePixels = [UInt8](repeating: 0, count: width * height)
        var instancePixels = [UInt8](repeating: 0, count: width * height)
        context.render(
            strokeSmall,
            toBitmap: &strokePixels,
            rowBytes: width,
            bounds: bounds,
            format: .L8,
            colorSpace: gray
        )
        context.render(
            instanceImage,
            toBitmap: &instancePixels,
            rowBytes: width,
            bounds: bounds,
            format: .L8,
            colorSpace: gray
        )
        for index in 0..<(width * height) {
            if strokePixels[index] > 16 && instancePixels[index] > 16 {
                return true
            }
        }
        return false
    }

    private static func dilate(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        image
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    private static func feather(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        image
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    private static func apply(mask: CIImage, to source: CGImage, extent: CGRect) throws -> CGImage {
        let sourceImage = CIImage(cgImage: source)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let blended = sourceImage
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ])
            .cropped(to: extent)

        if peakAlpha(blended) < 0.01 {
            throw SelectionMaskError.failed
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = context.createCGImage(blended, from: extent, format: .BGRA8, colorSpace: srgb) else {
            throw SelectionMaskError.failed
        }
        return image
    }

    private static func peakAlpha(_ image: CIImage) -> Float {
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            maximum,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: maximum.extent,
            format: .RGBAf,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixel[3]
    }

    private static let context: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: srgb,
            .outputColorSpace: srgb
        ])
    }()
}
