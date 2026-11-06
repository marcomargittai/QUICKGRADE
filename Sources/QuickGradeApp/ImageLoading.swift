import CoreGraphics
import QuickGradeCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageLoading {
    static func oriented(url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var maxSide = maxPixel
        if maxSide == nil,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            maxSide = max(width, height, 1)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let maxSide {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxSide
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Original long side divided by the bitmap long side. 1 when this bitmap is full resolution.
    static func grainScale(of image: CGImage, againstOriginal url: URL) -> CGFloat {
        let rendered = CGFloat(max(image.width, image.height))
        guard rendered > 1, let original = longSide(of: url) else { return 1 }
        return max(original / rendered, 1)
    }

    private static func longSide(of url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let side = max(width, height)
        return side > 1 ? CGFloat(side) : nil
    }

    static func write(_ image: CGImage, to destination: URL, copyingMetadataFrom sourceURL: URL) throws {
        let type = outputType(for: destination)
        try write(image, to: destination, type: type, copyingMetadataFrom: sourceURL)
    }

    static func destinationURL(for source: URL, preferredExtension: String? = nil) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = preferredExtension ?? outputExtension(for: source)
        var index = 0
        while true {
            let suffix = index == 0 ? " graded" : " graded \(index + 1)"
            let url = folder.appendingPathComponent(stem + suffix).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    static func images(inSameFolderAs url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [url]
        }
        let photos = urls.filter(ImageKind.isPhoto).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return photos.isEmpty ? [url] : photos
    }

    private static func outputExtension(for source: URL) -> String {
        switch source.pathExtension.lowercased() {
        case "png": return "png"
        case "tif", "tiff": return "tiff"
        case "heic", "heif": return "heic"
        default: return "jpg"
        }
    }

    private static func outputType(for destination: URL) -> UTType {
        switch destination.pathExtension.lowercased() {
        case "png": return .png
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        default: return .jpeg
        }
    }

    private static func write(_ image: CGImage, to destination: URL, type: UTType, copyingMetadataFrom sourceURL: URL) throws {
        // The selected file keeps its extension. A cropped JPEG is still JPEG,
        // even when the bitmap has an alpha channel.
        let image = type == .jpeg ? flattened(image) : image
        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = metadata
        }
        properties[kCGImagePropertyOrientation] = 1
        if type == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        if !finalize(image, to: destination, type: type, properties: properties) {
            var basic: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            if type == .jpeg {
                basic[kCGImageDestinationLossyCompressionQuality] = 0.92
            }
            guard finalize(image, to: destination, type: type, properties: basic) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func finalize(_ image: CGImage, to destination: URL, type: UTType, properties: [CFString: Any]) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// JPEG cannot store alpha. Draw onto white so a crop does not get rewritten as PNG.
    private static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return image }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
