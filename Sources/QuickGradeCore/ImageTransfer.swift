import CoreGraphics
import Foundation
import ImageIO

public enum ImageTransfer {
    /// True if any sampled pixel has alpha below 250/255. Sample on a grid (about every 8 px, always include corners) so a large photo stays cheap. A fully opaque image returns false.
    public static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        if let alpha = alphaFromProvider(image) {
            return alpha
        }
        return alphaFromRedraw(image)
    }

    /// Extension for a saved COPY next to the original. Never changes the original.
    /// - Opaque: keep the source extension if it is jpg, jpeg, png, tif, tiff, heic, or heif. Anything else (webp, gif, bmp, ...) becomes jpg.
    /// - Transparent: png, except when the source is tif or tiff (those stay tiff, which holds alpha). Never return jpg, jpeg, heic, heif, webp, or gif for a transparent image.
    public static func exportExtension(sourceExtension: String, transparent: Bool) -> String {
        var ext = sourceExtension.lowercased()
        if ext.hasPrefix(".") {
            ext.removeFirst()
        }

        if transparent {
            if ext == "tif" || ext == "tiff" {
                return "tiff"
            }
            return "png"
        }

        switch ext {
        case "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif":
            return ext
        default:
            return "jpg"
        }
    }

    /// Bytes and a pasteboard type for copying the image the user is looking at.
    /// Always PNG data (public.png). Transparency survives, and opaque photos still paste everywhere.
    /// Also fine to include no other types. Return nil only if encoding fails.
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static let alphaOpaqueFloor: UInt8 = 250
    private static let sampleStep = 8

    private static func sampleIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var indices: [Int] = []
        var i = 0
        while i < count {
            indices.append(i)
            i += sampleStep
        }
        let last = count - 1
        if indices.last != last {
            indices.append(last)
        }
        return indices
    }

    private static func hasClearSample(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        alphaOffset: Int
    ) -> Bool {
        for y in sampleIndices(count: height) {
            let row = pixels + y * bytesPerRow
            for x in sampleIndices(count: width) {
                if row[x * bytesPerPixel + alphaOffset] < alphaOpaqueFloor {
                    return true
                }
            }
        }
        return false
    }

    private static func alphaByteOffset(in image: CGImage) -> Int? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32 else { return nil }

        let alphaFirst: Bool
        switch image.alphaInfo {
        case .premultipliedFirst, .first:
            alphaFirst = true
        case .premultipliedLast, .last:
            alphaFirst = false
        default:
            return nil
        }

        let order = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        switch order {
        case .byteOrder32Little:
            return alphaFirst ? 3 : 0
        default:
            return alphaFirst ? 0 : 3
        }
    }

    private static func alphaFromProvider(_ image: CGImage) -> Bool? {
        guard
            let offset = alphaByteOffset(in: image),
            let provider = image.dataProvider,
            let data = provider.data,
            let base = CFDataGetBytePtr(data)
        else {
            return nil
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = 4
        let needed = bytesPerRow * (height - 1) + width * bytesPerPixel
        guard CFDataGetLength(data) >= needed else { return nil }

        return hasClearSample(
            pixels: base,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            alphaOffset: offset
        )
    }

    private static func alphaFromRedraw(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return hasClearSample(
                pixels: base,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: 4,
                alphaOffset: 3
            )
        }
    }
}
