import CoreGraphics
import Foundation

public struct Histogram: Equatable, Sendable {
    public var luma: [Float]
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(luma: [Float], red: [Float], green: [Float], blue: [Float]) {
        self.luma = luma
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static func empty(bins: Int = 64) -> Histogram {
        Histogram(
            luma: Array(repeating: 0, count: bins),
            red: Array(repeating: 0, count: bins),
            green: Array(repeating: 0, count: bins),
            blue: Array(repeating: 0, count: bins)
        )
    }

    public static func compute(_ image: CGImage, bins: Int = 64) -> Histogram {
        let sampleWidth = 160
        let sampleHeight = max(1, sampleWidth * image.height / max(image.width, 1))
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .empty(bins: bins)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var luma = [Int](repeating: 0, count: bins)
        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)
        let count = sampleWidth * sampleHeight
        for index in 0..<count {
            let o = index * 4
            let r = Int(pixels[o])
            let g = Int(pixels[o + 1])
            let b = Int(pixels[o + 2])
            let y = (54 * r + 183 * g + 19 * b) >> 8
            luma[min(bins - 1, y * bins / 256)] += 1
            red[min(bins - 1, r * bins / 256)] += 1
            green[min(bins - 1, g * bins / 256)] += 1
            blue[min(bins - 1, b * bins / 256)] += 1
        }
        func normalize(_ bins: [Int]) -> [Float] {
            let peak = bins.max() ?? 1
            let scale = Float(max(peak, 1))
            return bins.map { Float($0) / scale }
        }
        return Histogram(luma: normalize(luma), red: normalize(red), green: normalize(green), blue: normalize(blue))
    }
}
