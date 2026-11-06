import CoreGraphics
import CoreImage
import Vision

public enum SubjectCutoutError: Error, Equatable {
    case unsupported
    case noSubject
    case failed
}

public enum SubjectCutout {
    /// Returns a CGImage with a premultiplied alpha of the foreground subject, same pixel size as the source. Throws SubjectCutoutError if Vision finds nothing or fails.
    public static func cutout(source: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        let maskBuffer = try mask(from: handler)
        return try apply(mask: maskBuffer, to: source)
    }

    private static func mask(from handler: VNImageRequestHandler) throws -> CVPixelBuffer {
        if !VNGenerateForegroundInstanceMaskRequest.supportedRevisions.isEmpty {
            return try foregroundMask(handler: handler)
        }
        if !VNGeneratePersonSegmentationRequest.supportedRevisions.isEmpty {
            return try personMask(handler: handler)
        }
        throw SubjectCutoutError.unsupported
    }

    private static func foregroundMask(handler: VNImageRequestHandler) throws -> CVPixelBuffer {
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw SubjectCutoutError.failed
        }
        guard let observation = request.results?.first else {
            throw SubjectCutoutError.noSubject
        }
        let instances = observation.allInstances
        guard !instances.isEmpty else {
            throw SubjectCutoutError.noSubject
        }
        do {
            return try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        } catch {
            throw SubjectCutoutError.failed
        }
    }

    private static func personMask(handler: VNImageRequestHandler) throws -> CVPixelBuffer {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        do {
            try handler.perform([request])
        } catch {
            throw SubjectCutoutError.failed
        }
        guard let observation = request.results?.first else {
            throw SubjectCutoutError.noSubject
        }
        return observation.pixelBuffer
    }

    private static func apply(mask: CVPixelBuffer, to source: CGImage) throws -> CGImage {
        let sourceImage = CIImage(cgImage: source)
        let extent = sourceImage.extent
        var maskImage = CIImage(cvPixelBuffer: mask)
        let scaleX = extent.width / max(maskImage.extent.width, 1)
        let scaleY = extent.height / max(maskImage.extent.height, 1)
        if scaleX != 1 || scaleY != 1 {
            maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        maskImage = maskImage.cropped(to: extent)

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let blended = sourceImage
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: maskImage
            ])
            .cropped(to: extent)

        if meanAlpha(blended) < 0.01 {
            throw SubjectCutoutError.noSubject
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = context.createCGImage(blended, from: extent, format: .BGRA8, colorSpace: srgb) else {
            throw SubjectCutoutError.failed
        }
        return image
    }

    private static func meanAlpha(_ image: CIImage) -> Float {
        let average = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: average.extent,
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
