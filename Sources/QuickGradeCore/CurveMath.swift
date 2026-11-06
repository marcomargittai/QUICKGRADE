import Foundation

public enum CurveMath {
    /// Monotone cubic (Fritsch–Carlson). y is clamped to 0...1.
    public static func value(points: [CurvePoint], at x: Double) -> Double {
        let pts = sanitized(points)
        guard pts.count >= 2 else { return min(max(x, 0), 1) }
        if x <= pts[0].x { return clamp(pts[0].y) }
        if x >= pts[pts.count - 1].x { return clamp(pts[pts.count - 1].y) }

        let tangents = fritschCarlson(pts)
        var index = 0
        while index < pts.count - 2 && pts[index + 1].x < x {
            index += 1
        }
        let x0 = pts[index].x
        let x1 = pts[index + 1].x
        let span = x1 - x0
        if span < 1e-8 { return clamp(pts[index].y) }
        let t = (x - x0) / span
        let y = hermite(
            t: t,
            y0: pts[index].y,
            y1: pts[index + 1].y,
            m0: tangents[index],
            m1: tangents[index + 1],
            span: span
        )
        return clamp(y)
    }

    public static func samples(points: [CurvePoint], count: Int) -> [Double] {
        guard count > 1 else { return [value(points: points, at: 0)] }
        return (0..<count).map { index in
            value(points: points, at: Double(index) / Double(count - 1))
        }
    }

    public static func sanitized(_ points: [CurvePoint]) -> [CurvePoint] {
        let sorted = points.sorted { $0.x < $1.x }
        var unique: [CurvePoint] = []
        for point in sorted {
            if let last = unique.last, abs(last.x - point.x) < 1e-4 {
                unique[unique.count - 1] = point
            } else {
                unique.append(point)
            }
        }
        return unique
    }

    private static func fritschCarlson(_ pts: [CurvePoint]) -> [Double] {
        let n = pts.count - 1
        var secant = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let dx = pts[i + 1].x - pts[i].x
            secant[i] = dx < 1e-8 ? 0 : (pts[i + 1].y - pts[i].y) / dx
        }
        var m = [Double](repeating: 0, count: pts.count)
        m[0] = secant[0]
        m[n] = secant[n - 1]
        if n > 1 {
            for i in 1..<n {
                m[i] = (secant[i - 1] + secant[i]) * 0.5
            }
        }
        for i in 0..<n where abs(secant[i]) < 1e-8 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<n {
            if abs(secant[i]) < 1e-8 { continue }
            let a = m[i] / secant[i]
            let b = m[i + 1] / secant[i]
            let sum = a * a + b * b
            if sum > 9 {
                let tau = 3 / sqrt(sum)
                m[i] = tau * a * secant[i]
                m[i + 1] = tau * b * secant[i]
            }
        }
        return m
    }

    private static func hermite(t: Double, y0: Double, y1: Double, m0: Double, m1: Double, span: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * y0 + h10 * span * m0 + h01 * y1 + h11 * span * m1
    }

    private static func clamp(_ y: Double) -> Double { min(max(y, 0), 1) }
}
