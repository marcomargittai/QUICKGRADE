import CoreGraphics
import Foundation

/// One pen stroke drawn on the finished photo.
/// Points are 0...1 across the output image, origin top-left. Width is a fraction of the long side.
public struct MarkupStroke: Codable, Equatable, Sendable {
    public var points: [CGPoint]
    public var width: Double
    public var color: MarkupColor

    public init(points: [CGPoint], width: Double, color: MarkupColor) {
        self.points = points
        self.width = width
        self.color = color
    }
}

public enum MarkupColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case white, black, pink, yellow, green, blue

    public var id: String { rawValue }

    public var rgb: (Double, Double, Double) {
        switch self {
        case .white: return (1, 1, 1)
        case .black: return (0.06, 0.06, 0.07)
        case .pink: return (1, 0.22, 0.42)
        case .yellow: return (1, 0.84, 0.04)
        case .green: return (0.2, 0.84, 0.4)
        case .blue: return (0.04, 0.52, 1)
        }
    }

    public var title: String { rawValue.capitalized }
}

public enum MarkupSize: Int, CaseIterable, Identifiable, Sendable {
    case fine, medium, bold

    public var id: Int { rawValue }

    /// Fraction of the image's long side.
    public var width: Double {
        switch self {
        case .fine: return 0.0035
        case .medium: return 0.008
        case .bold: return 0.016
        }
    }

    public var title: String {
        switch self {
        case .fine: return "Fine"
        case .medium: return "Medium"
        case .bold: return "Bold"
        }
    }
}

public enum Markup {
    /// Smooth path through the points: quadratic curves between midpoints.
    /// `size` maps 0...1 points into the drawing space. Origin stays top-left.
    public static func path(_ points: [CGPoint], in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let scaled = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = scaled.first else { return path }
        path.move(to: first)
        guard scaled.count > 1 else {
            // Zero-length line. A round cap turns it into a dot.
            path.addLine(to: first)
            return path
        }
        guard scaled.count > 2 else {
            path.addLine(to: scaled[1])
            return path
        }
        for index in 1..<(scaled.count - 1) {
            let control = scaled[index]
            let next = scaled[index + 1]
            let mid = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: control)
        }
        path.addLine(to: scaled[scaled.count - 1])
        return path
    }

    /// Line width in points for a stroke drawn over `size`.
    public static func lineWidth(_ stroke: MarkupStroke, in size: CGSize) -> CGFloat {
        max(CGFloat(stroke.width) * max(size.width, size.height), 1)
    }

    /// True when `point` (0...1) lies on the stroke, with `slack` extra reach in 0...1 units of the long side.
    public static func hits(_ stroke: MarkupStroke, at point: CGPoint, aspect: CGFloat, slack: Double) -> Bool {
        let safe = max(aspect, 0.01)
        // Measure in a space where the long side is 1.
        let scale = safe >= 1 ? CGSize(width: 1, height: 1 / safe) : CGSize(width: safe, height: 1)
        func mapped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale.width, y: p.y * scale.height) }
        let target = mapped(point)
        let reach = stroke.width / 2 + slack
        let points = stroke.points.map(mapped)
        guard let first = points.first else { return false }
        if points.count == 1 { return hypot(first.x - target.x, first.y - target.y) <= reach }
        for index in 1..<points.count {
            if distance(from: target, toSegment: points[index - 1], points[index]) <= reach { return true }
        }
        return false
    }

    /// Draws the strokes over a copy of `image`.
    public static func drawing(_ strokes: [MarkupStroke], over image: CGImage) -> CGImage {
        guard !strokes.isEmpty else { return image }
        let width = image.width
        let height = image.height
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo = image.alphaInfo
        let keepsAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
        let info = keepsAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: info
        ) else { return image }
        let size = CGSize(width: width, height: height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Strokes use a top-left origin.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            let rgb = stroke.color.rgb
            context.setStrokeColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            context.setLineWidth(lineWidth(stroke, in: size))
            context.addPath(path(stroke.points, in: size))
            context.strokePath()
        }
        return context.makeImage() ?? image
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
