import CoreGraphics
import Foundation

public enum CropAspect: String, Codable, CaseIterable, Identifiable, Equatable {
    case free
    case original
    case square
    case threeByTwo = "3:2"
    case fourByThree = "4:3"
    case fiveByThree = "5:3"
    case fiveByFour = "5:4"
    case sevenByFive = "7:5"
    case sixteenByNine = "16:9"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "Square"
        case .threeByTwo, .fourByThree, .fiveByThree, .fiveByFour, .sevenByFive, .sixteenByNine:
            return rawValue
        }
    }

    /// Portrait frames show the numbers reversed, so a selected 4:3 reads as 3:4.
    public func title(matching pixelRatio: CGFloat) -> String {
        switch self {
        case .free, .original, .square:
            return title
        case .threeByTwo, .fourByThree, .fiveByThree, .fiveByFour, .sevenByFive, .sixteenByNine:
            let parts = rawValue.split(separator: ":")
            guard parts.count == 2, pixelRatio < 1 else { return title }
            return "\(parts[1]):\(parts[0])"
        }
    }

    public var landscapeRatio: CGFloat? {
        switch self {
        case .free: return nil
        case .original: return nil
        case .square: return 1
        case .threeByTwo: return 3 / 2
        case .fourByThree: return 4 / 3
        case .fiveByThree: return 5 / 3
        case .fiveByFour: return 5 / 4
        case .sevenByFive: return 7 / 5
        case .sixteenByNine: return 16 / 9
        }
    }
}

/// Normalized crop in the oriented image the user sees.
/// Origin is the top-left of that image, y down, each side in 0...1.
public struct CropEdit: Codable, Equatable {
    public var aspect: CropAspect
    public var rect: CGRect
    public var quarterTurns: Int
    public var mirrored: Bool
    public var straighten: Double

    public static let identity = CropEdit()

    public init(
        aspect: CropAspect = .free,
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        quarterTurns: Int = 0,
        mirrored: Bool = false,
        straighten: Double = 0
    ) {
        self.aspect = aspect
        self.rect = Self.clamped(rect)
        var turns = quarterTurns % 4
        if turns < 0 { turns += 4 }
        self.quarterTurns = turns
        self.mirrored = mirrored
        self.straighten = min(max(straighten, -45), 45)
        if abs(self.straighten) < 1e-9 { self.straighten = 0 }
    }

    public var isIdentity: Bool {
        aspect == .free
            && quarterTurns == 0
            && !mirrored
            && abs(straighten) < 1e-9
            && abs(rect.minX) < 1e-6
            && abs(rect.minY) < 1e-6
            && abs(rect.width - 1) < 1e-6
            && abs(rect.height - 1) < 1e-6
    }

    public func rotatedLeft() -> CropEdit {
        let next = CGRect(
            x: rect.minY,
            y: 1 - rect.maxX,
            width: rect.height,
            height: rect.width
        )
        return CropEdit(
            aspect: aspect,
            rect: next,
            quarterTurns: quarterTurns + 1,
            mirrored: mirrored,
            straighten: straighten
        )
    }

    public func flipped() -> CropEdit {
        let next = CGRect(
            x: 1 - rect.maxX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
        return CropEdit(
            aspect: aspect,
            rect: next,
            quarterTurns: quarterTurns,
            mirrored: !mirrored,
            straighten: straighten
        )
    }

    public func locked(to aspect: CropAspect, imageAspect: CGFloat) -> CropEdit {
        var next = CropEdit(
            aspect: aspect,
            rect: rect,
            quarterTurns: quarterTurns,
            mirrored: mirrored,
            straighten: straighten
        )
        guard aspect != .free else { return next }
        let ratio = next.resolvedPixelRatio(imageAspect: imageAspect)
        next.rect = CropGeometry.aspectLockedRect(
            around: rect,
            pixelRatio: ratio,
            displayAspect: CropGeometry.displayAspect(edit: next, imageAspect: imageAspect)
        )
        if abs(next.straighten) > 1e-9 {
            next.rect = CropGeometry.largestFilledRect(
                around: next.rect,
                pixelRatio: ratio,
                edit: next,
                imageAspect: imageAspect
            )
        }
        return CropEdit(
            aspect: next.aspect,
            rect: next.rect,
            quarterTurns: next.quarterTurns,
            mirrored: next.mirrored,
            straighten: next.straighten
        )
    }

    public var swapsWhenPressedAgain: Bool {
        switch aspect {
        case .free, .square:
            return false
        case .original, .threeByTwo, .fourByThree, .fiveByThree, .fiveByFour, .sevenByFive, .sixteenByNine:
            return true
        }
    }

    /// Same preset with width and height exchanged. 3:4 becomes 4:3.
    public func swappedSides(imageAspect: CGFloat) -> CropEdit {
        guard swapsWhenPressedAgain else { return self }
        let flipped = 1 / max(resolvedPixelRatio(imageAspect: imageAspect), 1e-8)
        var next = CropEdit(
            aspect: aspect,
            rect: rect,
            quarterTurns: quarterTurns,
            mirrored: mirrored,
            straighten: straighten
        )
        let display = CropGeometry.displayAspect(edit: next, imageAspect: imageAspect)
        next.rect = CropGeometry.aspectLockedRect(
            around: rect,
            pixelRatio: flipped,
            displayAspect: display
        )
        if abs(next.straighten) > 1e-9 {
            next.rect = CropGeometry.largestFilledRect(
                around: next.rect,
                pixelRatio: flipped,
                edit: next,
                imageAspect: imageAspect
            )
        }
        return CropEdit(
            aspect: next.aspect,
            rect: next.rect,
            quarterTurns: next.quarterTurns,
            mirrored: next.mirrored,
            straighten: next.straighten
        )
    }

    public func straightened(_ degrees: Double, imageAspect: CGFloat) -> CropEdit {
        let ratio = resolvedPixelRatio(imageAspect: imageAspect)
        let next = CropEdit(
            aspect: aspect,
            rect: rect,
            quarterTurns: quarterTurns,
            mirrored: mirrored,
            straighten: degrees
        )
        if abs(next.straighten) < 1e-9 {
            return next
        }
        if CropGeometry.isFilled(rect, edit: next, imageAspect: imageAspect) {
            return next
        }
        let filled = CropGeometry.largestFilledRect(
            around: rect,
            pixelRatio: ratio,
            edit: next,
            imageAspect: imageAspect
        )
        return CropEdit(
            aspect: next.aspect,
            rect: filled,
            quarterTurns: next.quarterTurns,
            mirrored: next.mirrored,
            straighten: next.straighten
        )
    }

    public func resetting() -> CropEdit { .identity }

    public func replacing(rect: CGRect) -> CropEdit {
        var next = self
        next.rect = rect
        return next
    }


    /// Pixel width / height of the crop this preset (or the current free rect) should keep.
    public func resolvedPixelRatio(imageAspect: CGFloat) -> CGFloat {
        let display = CropGeometry.displayAspect(edit: self, imageAspect: imageAspect)
        let current = (rect.width / max(rect.height, 1e-8)) * display
        let base: CGFloat
        switch aspect {
        case .free:
            return current
        case .original:
            base = max(imageAspect, 1e-8)
        case .square, .threeByTwo, .fourByThree, .fiveByThree, .fiveByFour, .sevenByFive, .sixteenByNine:
            base = aspect.landscapeRatio ?? 1
        }
        return current < 1 ? 1 / base : base
    }

    public static func clamped(_ rect: CGRect) -> CGRect {
        var width = min(max(rect.width, 0.05), 1)
        var height = min(max(rect.height, 0.05), 1)
        var x = rect.origin.x
        var y = rect.origin.y
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x + width > 1 { x = 1 - width }
        if y + height > 1 { y = 1 - height }
        x = min(max(x, 0), 1 - width)
        y = min(max(y, 0), 1 - height)
        width = min(width, 1 - x)
        height = min(height, 1 - y)
        return CGRect(x: x, y: y, width: max(width, 0.05), height: max(height, 0.05))
    }
}

public enum CropHandle: Equatable {
    case nw, n, ne, e, se, s, sw, w, body

    var movesLeft: Bool {
        switch self {
        case .nw, .w, .sw: return true
        default: return false
        }
    }

    var movesTop: Bool {
        switch self {
        case .nw, .n, .ne: return true
        default: return false
        }
    }
}

public enum CropGeometry {
    /// The crop frame stays put on screen while the image is scaled around its center
    /// and shifted by `pan`. This is the image region currently inside that frame.
    public static func imageRect(covering frame: CGRect, zoom: CGFloat, pan: CGSize, viewSize: CGSize) -> CGRect {
        let width = max(viewSize.width, 1)
        let height = max(viewSize.height, 1)
        let scale = max(zoom, 0.01)
        let center = CGPoint(x: width / 2, y: height / 2)
        func map(_ unit: CGPoint) -> CGPoint {
            let point = CGPoint(x: unit.x * width, y: unit.y * height)
            let image = CGPoint(
                x: center.x + (point.x - center.x - pan.width) / scale,
                y: center.y + (point.y - center.y - pan.height) / scale
            )
            return CGPoint(x: image.x / width, y: image.y / height)
        }
        let minPoint = map(CGPoint(x: frame.minX, y: frame.minY))
        let maxPoint = map(CGPoint(x: frame.maxX, y: frame.maxY))
        return CropEdit.clamped(CGRect(
            x: minPoint.x,
            y: minPoint.y,
            width: maxPoint.x - minPoint.x,
            height: maxPoint.y - minPoint.y
        ))
    }

    /// Aspect of the oriented, straightened image the user sees (before the crop inset).
    public static func displayAspect(edit: CropEdit, imageAspect: CGFloat) -> CGFloat {
        let size = orientedSize(edit: edit, pixelSize: CGSize(width: max(imageAspect, 1e-6), height: 1))
        return size.width / max(size.height, 1e-8)
    }

    /// Pixel size of the oriented bitmap after quarter turns and straighten.
    /// Straighten grows this to the axis-aligned bounds of the rotated image so a later
    /// crop can stay filled (no empty corners).
    public static func orientedSize(edit: CropEdit, pixelSize: CGSize) -> CGSize {
        var width = max(pixelSize.width, 1e-6)
        var height = max(pixelSize.height, 1e-6)
        if !edit.quarterTurns.isMultiple(of: 2) {
            swap(&width, &height)
        }
        let radians = edit.straighten * .pi / 180
        if abs(radians) < 1e-10 {
            return CGSize(width: width, height: height)
        }
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        return CGSize(
            width: width * cosine + height * sine,
            height: width * sine + height * cosine
        )
    }

    /// Pixel crop in the original image. Origin is the top-left of the source, y down.
    /// Quarter turns and mirror are inverted so the rect names the source pixels that stay framed.
    /// When straighten is not zero the crop is not axis-aligned in the source, so this returns
    /// the crop in the oriented bitmap (same space as orientedCrop).
    public static func pixelRect(edit: CropEdit, pixelSize: CGSize) -> CGRect {
        if abs(edit.straighten) > 1e-9 {
            return orientedCrop(edit: edit, orientedSize: orientedSize(edit: edit, pixelSize: pixelSize))
        }
        var normalized = edit.rect
        if edit.mirrored {
            normalized = CGRect(
                x: 1 - normalized.maxX,
                y: normalized.minY,
                width: normalized.width,
                height: normalized.height
            )
        }
        var turns = edit.quarterTurns % 4
        if turns < 0 { turns += 4 }
        for _ in 0..<turns {
            normalized = CGRect(
                x: 1 - normalized.maxY,
                y: normalized.minX,
                width: normalized.height,
                height: normalized.width
            )
        }
        return CGRect(
            x: normalized.minX * pixelSize.width,
            y: normalized.minY * pixelSize.height,
            width: normalized.width * pixelSize.width,
            height: normalized.height * pixelSize.height
        )
    }

    /// Crop in the oriented bitmap (after quarter turns, mirror, and straighten).
    /// Origin top-left, y down. `orientedSize` is that bitmap's pixel size.
    public static func orientedCrop(edit: CropEdit, orientedSize: CGSize) -> CGRect {
        CGRect(
            x: edit.rect.minX * orientedSize.width,
            y: edit.rect.minY * orientedSize.height,
            width: edit.rect.width * orientedSize.width,
            height: edit.rect.height * orientedSize.height
        )
    }

    static func aspectLockedRect(around current: CGRect, pixelRatio: CGFloat, displayAspect: CGFloat) -> CGRect {
        let ratio = max(pixelRatio, 1e-8)
        let display = max(displayAspect, 1e-8)
        let normRatio = ratio / display
        var width: CGFloat
        var height: CGFloat
        if normRatio >= 1 {
            width = 1
            height = width / normRatio
            if height > 1 {
                height = 1
                width = height * normRatio
            }
        } else {
            height = 1
            width = height * normRatio
            if width > 1 {
                width = 1
                height = width / normRatio
            }
        }
        width = min(max(width, 0.05), 1)
        height = min(max(width / normRatio, 0.05), 1)
        if width > 1 {
            width = 1
            height = max(width / normRatio, 0.05)
        }
        if height > 1 {
            height = 1
            width = max(height * normRatio, 0.05)
        }
        var x = current.midX - width / 2
        var y = current.midY - height / 2
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x + width > 1 { x = 1 - width }
        if y + height > 1 { y = 1 - height }
        return CropEdit.clamped(CGRect(x: x, y: y, width: width, height: height))
    }

    static func largestFilledRect(
        around current: CGRect,
        pixelRatio: CGFloat,
        edit: CropEdit,
        imageAspect: CGFloat
    ) -> CGRect {
        let display = displayAspect(edit: edit, imageAspect: imageAspect)
        let normRatio = max(pixelRatio, 1e-8) / max(display, 1e-8)
        var center = CGPoint(x: current.midX, y: current.midY)

        func rect(at center: CGPoint, width: CGFloat) -> CGRect {
            let height = width / normRatio
            return CropEdit.clamped(
                CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            )
        }

        func valid(_ candidate: CGRect) -> Bool {
            isFilled(candidate, edit: edit, imageAspect: imageAspect)
        }

        if !valid(rect(at: center, width: 0.051)) {
            center = CGPoint(x: 0.5, y: 0.5)
        }

        var low: CGFloat = 0.05
        var high: CGFloat = 1
        for _ in 0..<28 {
            let mid = (low + high) / 2
            let candidate = rect(at: center, width: mid)
            if valid(candidate) && candidate.width + 1e-4 >= mid {
                low = mid
            } else {
                high = mid
            }
        }
        return rect(at: center, width: low)
    }

    static func isFilled(_ rect: CGRect, edit: CropEdit, imageAspect: CGFloat) -> Bool {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        return corners.allSatisfy { contains($0, edit: edit, imageAspect: imageAspect) }
    }

    static func contains(_ point: CGPoint, edit: CropEdit, imageAspect: CGFloat) -> Bool {
        if abs(edit.straighten) < 1e-9 {
            return point.x >= -1e-6 && point.y >= -1e-6 && point.x <= 1 + 1e-6 && point.y <= 1 + 1e-6
        }
        let source = CGSize(width: max(imageAspect, 1e-6), height: 1)
        let oriented = orientedSize(edit: edit, pixelSize: source)
        var sourceWidth = source.width
        var sourceHeight = source.height
        if !edit.quarterTurns.isMultiple(of: 2) {
            swap(&sourceWidth, &sourceHeight)
        }
        let px = point.x * oriented.width
        let py = point.y * oriented.height
        let centerX = px - oriented.width / 2
        let centerY = oriented.height / 2 - py
        let radians = edit.straighten * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let sourceX = centerX * cosine + centerY * sine
        let sourceY = -centerX * sine + centerY * cosine
        let pad: CGFloat = 1e-4
        return abs(sourceX) <= sourceWidth / 2 + pad && abs(sourceY) <= sourceHeight / 2 + pad
    }

    /// Resize or move a normalized crop. `lockRatio` keeps `normRatio` (width / height).
    /// `fromCenter` grows both sides the way Option does in Figma. `constrainAxis` locks a move to one axis.
    public static func draggedRect(
        start: CGRect,
        startPoint: CGPoint,
        point: CGPoint,
        canvas: CGSize,
        handle: CropHandle,
        lockRatio: Bool,
        fromCenter: Bool,
        constrainAxis: Bool,
        normRatio: CGFloat
    ) -> CGRect {
        let canvasW = max(canvas.width, 1)
        let canvasH = max(canvas.height, 1)
        if handle == .body {
            var dx = (point.x - startPoint.x) / canvasW
            var dy = (point.y - startPoint.y) / canvasH
            if constrainAxis {
                if abs(point.x - startPoint.x) >= abs(point.y - startPoint.y) {
                    dy = 0
                } else {
                    dx = 0
                }
            }
            return moved(start, dx: dx, dy: dy)
        }
        let nx = min(max(point.x / canvasW, 0), 1)
        let ny = min(max(point.y / canvasH, 0), 1)
        if fromCenter {
            return resizedFromCenter(handle: handle, start: start, nx: nx, ny: ny, lockRatio: lockRatio, normRatio: normRatio)
        }
        if lockRatio {
            return resizedAnchored(handle: handle, start: start, nx: nx, ny: ny, normRatio: normRatio)
        }
        return resizedFree(handle: handle, start: start, nx: nx, ny: ny)
    }

    private static func moved(_ start: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var x = start.minX + dx
        var y = start.minY + dy
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x + start.width > 1 { x = 1 - start.width }
        if y + start.height > 1 { y = 1 - start.height }
        return CropEdit.clamped(CGRect(x: x, y: y, width: start.width, height: start.height))
    }

    private static func resizedFree(handle: CropHandle, start: CGRect, nx: CGFloat, ny: CGFloat) -> CGRect {
        var left = start.minX
        var top = start.minY
        var right = start.maxX
        var bottom = start.maxY
        switch handle {
        case .n: top = ny
        case .s: bottom = ny
        case .w: left = nx
        case .e: right = nx
        case .nw: left = nx; top = ny
        case .ne: right = nx; top = ny
        case .sw: left = nx; bottom = ny
        case .se: right = nx; bottom = ny
        case .body: break
        }
        if right < left { swap(&left, &right) }
        if bottom < top { swap(&top, &bottom) }
        if right - left < 0.05 {
            if handle.movesLeft { left = right - 0.05 } else { right = left + 0.05 }
        }
        if bottom - top < 0.05 {
            if handle.movesTop { top = bottom - 0.05 } else { bottom = top + 0.05 }
        }
        return CropEdit.clamped(CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    private static func resizedFromCenter(
        handle: CropHandle,
        start: CGRect,
        nx: CGFloat,
        ny: CGFloat,
        lockRatio: Bool,
        normRatio: CGFloat
    ) -> CGRect {
        let cx = start.midX
        let cy = start.midY
        let ratio = max(normRatio, 1e-4)
        var halfW = start.width / 2
        var halfH = start.height / 2
        switch handle {
        case .e, .w:
            halfW = abs(nx - cx)
        case .n, .s:
            halfH = abs(ny - cy)
        case .nw, .ne, .sw, .se:
            halfW = abs(nx - cx)
            halfH = abs(ny - cy)
        case .body:
            break
        }
        if lockRatio {
            switch handle {
            case .e, .w:
                halfH = halfW / ratio
            case .n, .s:
                halfW = halfH * ratio
            default:
                let fromW = halfW / ratio
                let fromH = halfH * ratio
                if abs(fromW - halfH) <= abs(fromH - halfW) {
                    halfH = fromW
                } else {
                    halfW = fromH
                }
            }
        }
        let maxW = min(cx, 1 - cx)
        let maxH = min(cy, 1 - cy)
        if lockRatio {
            if halfW > maxW {
                halfW = maxW
                halfH = halfW / ratio
            }
            if halfH > maxH {
                halfH = maxH
                halfW = halfH * ratio
            }
            if halfW > maxW {
                halfW = maxW
                halfH = min(halfW / ratio, maxH)
            }
        } else {
            halfW = min(halfW, maxW)
            halfH = min(halfH, maxH)
        }
        let minHalf: CGFloat = 0.025
        if maxW >= minHalf { halfW = max(halfW, minHalf) }
        if maxH >= minHalf { halfH = max(halfH, minHalf) }
        halfW = min(max(halfW, 0), maxW)
        halfH = min(max(halfH, 0), maxH)
        return CropEdit.clamped(CGRect(x: cx - halfW, y: cy - halfH, width: halfW * 2, height: halfH * 2))
    }

    private static func resizedAnchored(
        handle: CropHandle,
        start: CGRect,
        nx: CGFloat,
        ny: CGFloat,
        normRatio: CGFloat
    ) -> CGRect {
        let ratio = max(normRatio, 1e-4)
        let minSize: CGFloat = 0.05
        switch handle {
        case .e, .w:
            let fixedX = handle == .e ? start.minX : start.maxX
            let towardRight = handle == .e
            var width = max(abs(nx - fixedX), minSize)
            var height = width / ratio
            let midY = start.midY
            let maxH = min(midY, 1 - midY) * 2
            let maxW = max(towardRight ? (1 - fixedX) : fixedX, minSize)
            if maxH > 0, height > maxH {
                height = maxH
                width = height * ratio
            }
            if width > maxW {
                width = maxW
                height = width / ratio
                if maxH > 0, height > maxH {
                    height = maxH
                    width = min(height * ratio, maxW)
                }
            }
            let x = towardRight ? fixedX : fixedX - width
            let y = midY - height / 2
            return CropEdit.clamped(CGRect(x: x, y: y, width: width, height: height))
        case .n, .s:
            let fixedY = handle == .s ? start.minY : start.maxY
            let towardDown = handle == .s
            var height = max(abs(ny - fixedY), minSize)
            var width = height * ratio
            let midX = start.midX
            let maxW = min(midX, 1 - midX) * 2
            let maxH = max(towardDown ? (1 - fixedY) : fixedY, minSize)
            if maxW > 0, width > maxW {
                width = maxW
                height = width / ratio
            }
            if height > maxH {
                height = maxH
                width = height * ratio
                if maxW > 0, width > maxW {
                    width = maxW
                    height = min(width / ratio, maxH)
                }
            }
            let x = midX - width / 2
            let y = towardDown ? fixedY : fixedY - height
            return CropEdit.clamped(CGRect(x: x, y: y, width: width, height: height))
        case .nw, .ne, .sw, .se:
            let anchorX = handle.movesLeft ? start.maxX : start.minX
            let anchorY = handle.movesTop ? start.maxY : start.minY
            let signX: CGFloat = nx - anchorX >= 0 ? 1 : -1
            let signY: CGFloat = ny - anchorY >= 0 ? 1 : -1
            var width = max(abs(nx - anchorX), minSize)
            var height = max(abs(ny - anchorY), minSize)
            let fromW = width / ratio
            let fromH = height * ratio
            if abs(fromW - height) <= abs(fromH - width) {
                height = fromW
            } else {
                width = fromH
            }
            let roomX = signX > 0 ? (1 - anchorX) : anchorX
            let roomY = signY > 0 ? (1 - anchorY) : anchorY
            if width > roomX {
                width = max(roomX, 0)
                height = width / ratio
            }
            if height > roomY {
                height = max(roomY, 0)
                width = height * ratio
            }
            if width > roomX {
                width = max(roomX, 0)
                height = min(width / ratio, roomY)
            }
            let x = signX > 0 ? anchorX : anchorX - width
            let y = signY > 0 ? anchorY : anchorY - height
            return CropEdit.clamped(CGRect(x: x, y: y, width: max(width, 0.05), height: max(height, 0.05)))
        case .body:
            return start
        }
    }
}
