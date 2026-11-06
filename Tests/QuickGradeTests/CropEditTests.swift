import CoreGraphics
import XCTest
@testable import QuickGradeCore

final class CropEditTests: XCTestCase {
    func testIdentityRectIsFullFrame() {
        let edit = CropEdit.identity
        XCTAssertEqual(edit.rect.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(edit.rect.origin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(edit.rect.width, 1, accuracy: 0.0001)
        XCTAssertEqual(edit.rect.height, 1, accuracy: 0.0001)
        XCTAssertTrue(edit.isIdentity)
        XCTAssertEqual(edit.quarterTurns, 0)
        XCTAssertFalse(edit.mirrored)
        XCTAssertEqual(edit.straighten, 0, accuracy: 0.0001)
        XCTAssertEqual(edit.aspect, .free)
    }

    func testLockSquareOnThreeByTwoIsCentered() {
        let edit = CropEdit.identity.locked(to: .square, imageAspect: 1.5)
        XCTAssertEqual(edit.aspect, .square)
        XCTAssertEqual(edit.rect.width, 2.0 / 3.0, accuracy: 0.002)
        XCTAssertEqual(edit.rect.height, 1, accuracy: 0.002)
        XCTAssertEqual(edit.rect.minX, 1.0 / 6.0, accuracy: 0.002)
        XCTAssertEqual(edit.rect.minY, 0, accuracy: 0.002)
        XCTAssertEqual(edit.rect.midX, 0.5, accuracy: 0.002)
        assertInsideUnit(edit.rect)
    }

    func testRotateLeftFourTimesReturnsIdentityRect() {
        var edit = CropEdit.identity
        for _ in 0..<4 {
            edit = edit.rotatedLeft()
        }
        XCTAssertEqual(edit.quarterTurns, 0)
        XCTAssertEqual(edit.rect.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(edit.rect.origin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(edit.rect.width, 1, accuracy: 0.0001)
        XCTAssertEqual(edit.rect.height, 1, accuracy: 0.0001)
        XCTAssertTrue(edit.isIdentity)

        let cropped = CropEdit(
            aspect: .free,
            rect: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)
        )
        var spun = cropped
        for _ in 0..<4 {
            spun = spun.rotatedLeft()
        }
        XCTAssertEqual(spun.rect.minX, cropped.rect.minX, accuracy: 0.0001)
        XCTAssertEqual(spun.rect.minY, cropped.rect.minY, accuracy: 0.0001)
        XCTAssertEqual(spun.rect.width, cropped.rect.width, accuracy: 0.0001)
        XCTAssertEqual(spun.rect.height, cropped.rect.height, accuracy: 0.0001)
    }

    func testMirrorTwiceIsIdentity() {
        let once = CropEdit.identity.flipped()
        XCTAssertTrue(once.mirrored)
        XCTAssertFalse(once.isIdentity)
        let twice = once.flipped()
        XCTAssertFalse(twice.mirrored)
        XCTAssertTrue(twice.isIdentity)
        XCTAssertEqual(twice.rect.width, 1, accuracy: 0.0001)
        XCTAssertEqual(twice.rect.minX, 0, accuracy: 0.0001)
    }

    func testStraightenZeroDoesNotChangeRect() {
        let start = CropEdit.identity.locked(to: .square, imageAspect: 1.5)
        let next = start.straightened(0, imageAspect: 1.5)
        XCTAssertEqual(next.rect.minX, start.rect.minX, accuracy: 0.0001)
        XCTAssertEqual(next.rect.minY, start.rect.minY, accuracy: 0.0001)
        XCTAssertEqual(next.rect.width, start.rect.width, accuracy: 0.0001)
        XCTAssertEqual(next.rect.height, start.rect.height, accuracy: 0.0001)
        XCTAssertEqual(next.straighten, 0, accuracy: 0.0001)
    }

    func testStraightenTwentyKeepsCropInsideAndAspect() {
        let edit = CropEdit.identity
            .locked(to: .square, imageAspect: 1.5)
            .straightened(20, imageAspect: 1.5)
        assertInsideUnit(edit.rect)
        XCTAssertEqual(edit.straighten, 20, accuracy: 0.0001)

        let oriented = CropGeometry.orientedSize(edit: edit, pixelSize: CGSize(width: 1500, height: 1000))
        let crop = CropGeometry.orientedCrop(edit: edit, orientedSize: oriented)
        XCTAssertGreaterThanOrEqual(crop.minX, -0.01)
        XCTAssertGreaterThanOrEqual(crop.minY, -0.01)
        XCTAssertLessThanOrEqual(crop.maxX, oriented.width + 0.01)
        XCTAssertLessThanOrEqual(crop.maxY, oriented.height + 0.01)
        XCTAssertEqual(crop.width / max(crop.height, 1e-6), 1, accuracy: 0.02)
        XCTAssertTrue(CropGeometry.isFilled(edit.rect, edit: edit, imageAspect: 1.5))
    }

    func testRectNeverLeavesUnitSquare() {
        let aspects: [CropAspect] = CropAspect.allCases
        var edit = CropEdit.identity
        for aspect in aspects {
            edit = edit.locked(to: aspect, imageAspect: 1.5)
            assertInsideUnit(edit.rect)
            edit = edit.rotatedLeft()
            assertInsideUnit(edit.rect)
            edit = edit.flipped()
            assertInsideUnit(edit.rect)
            edit = edit.straightened(20, imageAspect: 1.5)
            assertInsideUnit(edit.rect)
            edit = edit.straightened(-45, imageAspect: 3 / 2)
            assertInsideUnit(edit.rect)
            edit = edit.straightened(0, imageAspect: 1.5)
            assertInsideUnit(edit.rect)
        }
        let tiny = CropEdit(rect: CGRect(x: -2, y: 3, width: 0.01, height: 8))
        assertInsideUnit(tiny.rect)
        XCTAssertGreaterThanOrEqual(tiny.rect.width, 0.05)
        XCTAssertGreaterThanOrEqual(tiny.rect.height, 0.05)
    }

    func testPixelRectMapsIdentityAndTurns() {
        let size = CGSize(width: 300, height: 200)
        let full = CropGeometry.pixelRect(edit: .identity, pixelSize: size)
        XCTAssertEqual(full.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(full.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(full.width, 300, accuracy: 0.001)
        XCTAssertEqual(full.height, 200, accuracy: 0.001)

        let left = CropEdit(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let pixels = CropGeometry.pixelRect(edit: left, pixelSize: size)
        XCTAssertEqual(pixels.width, 150, accuracy: 0.001)
        XCTAssertEqual(pixels.height, 200, accuracy: 0.001)

        let turned = left.rotatedLeft()
        let turnedPixels = CropGeometry.pixelRect(edit: turned, pixelSize: size)
        XCTAssertEqual(turned.quarterTurns, 1)
        XCTAssertGreaterThan(turnedPixels.width, 0)
        XCTAssertGreaterThan(turnedPixels.height, 0)
    }

    func testShiftKeepsRatioFromTheOppositeCorner() {
        let start = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let next = CropGeometry.draggedRect(
            start: start,
            startPoint: .zero,
            point: CGPoint(x: 90, y: 60),
            canvas: CGSize(width: 100, height: 100),
            handle: .se,
            lockRatio: true,
            fromCenter: false,
            constrainAxis: false,
            normRatio: 1
        )
        XCTAssertEqual(next.width, next.height, accuracy: 0.001)
        XCTAssertEqual(next.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(next.minY, 0.25, accuracy: 0.001)
        XCTAssertEqual(next.maxX, 0.9, accuracy: 0.001)
        assertInsideUnit(next)
    }

    func testOptionResizesFromTheCenter() {
        let start = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let next = CropGeometry.draggedRect(
            start: start,
            startPoint: .zero,
            point: CGPoint(x: 80, y: 50),
            canvas: CGSize(width: 100, height: 100),
            handle: .e,
            lockRatio: false,
            fromCenter: true,
            constrainAxis: false,
            normRatio: 1
        )
        XCTAssertEqual(next.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(next.midY, 0.5, accuracy: 0.001)
        XCTAssertEqual(next.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(next.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(next.height, 0.5, accuracy: 0.001)
        assertInsideUnit(next)
    }

    func testShiftOptionKeepsRatioAroundTheCenter() {
        let start = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let next = CropGeometry.draggedRect(
            start: start,
            startPoint: .zero,
            point: CGPoint(x: 80, y: 60),
            canvas: CGSize(width: 100, height: 100),
            handle: .se,
            lockRatio: true,
            fromCenter: true,
            constrainAxis: true,
            normRatio: 1
        )
        XCTAssertEqual(next.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(next.midY, 0.5, accuracy: 0.001)
        XCTAssertEqual(next.width, next.height, accuracy: 0.001)
        XCTAssertEqual(next.width, 0.6, accuracy: 0.001)
        assertInsideUnit(next)
    }

    func testShiftConstrainsCropMoveToOneAxis() {
        let start = CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.3)
        let next = CropGeometry.draggedRect(
            start: start,
            startPoint: CGPoint(x: 40, y: 40),
            point: CGPoint(x: 70, y: 45),
            canvas: CGSize(width: 100, height: 100),
            handle: .body,
            lockRatio: true,
            fromCenter: false,
            constrainAxis: true,
            normRatio: start.width / start.height
        )
        XCTAssertEqual(next.minY, start.minY, accuracy: 0.001)
        XCTAssertEqual(next.minX, 0.55, accuracy: 0.001)
        XCTAssertEqual(next.width, start.width, accuracy: 0.001)
        XCTAssertEqual(next.height, start.height, accuracy: 0.001)
    }

    func testZoomKeepsTheCropShape() {
        let frame = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        let view = CGSize(width: 400, height: 200)
        let zoomed = CropGeometry.imageRect(covering: frame, zoom: 2, pan: .zero, viewSize: view)
        let before = (frame.width * view.width) / (frame.height * view.height)
        let after = (zoomed.width * view.width) / (zoomed.height * view.height)
        XCTAssertEqual(after, before, accuracy: 0.001)
        XCTAssertLessThan(zoomed.width, frame.width)
        let idle = CropGeometry.imageRect(covering: frame, zoom: 1, pan: .zero, viewSize: view)
        XCTAssertEqual(idle.minX, frame.minX, accuracy: 0.001)
        XCTAssertEqual(idle.width, frame.width, accuracy: 0.001)
        XCTAssertEqual(idle.height, frame.height, accuracy: 0.001)
    }

    func testPressingSelectedRatioSwapsSides() {
        let portrait: CGFloat = 3.0 / 4.0
        let first = CropEdit.identity.locked(to: .fourByThree, imageAspect: portrait)
        let firstRatio = first.resolvedPixelRatio(imageAspect: portrait)
        XCTAssertEqual(firstRatio, 3.0 / 4.0, accuracy: 0.02)
        XCTAssertEqual(CropAspect.fourByThree.title(matching: firstRatio), "3:4")

        let second = first.swappedSides(imageAspect: portrait)
        let secondRatio = second.resolvedPixelRatio(imageAspect: portrait)
        XCTAssertEqual(second.aspect, .fourByThree)
        XCTAssertEqual(secondRatio, 4.0 / 3.0, accuracy: 0.02)
        XCTAssertEqual(CropAspect.fourByThree.title(matching: secondRatio), "4:3")
        assertInsideUnit(second.rect)

        let third = second.swappedSides(imageAspect: portrait)
        XCTAssertEqual(third.resolvedPixelRatio(imageAspect: portrait), firstRatio, accuracy: 0.02)

        let square = CropEdit.identity.locked(to: .square, imageAspect: portrait)
        let still = square.swappedSides(imageAspect: portrait)
        XCTAssertEqual(still.rect.width, square.rect.width, accuracy: 0.0001)
        XCTAssertEqual(still.rect.height, square.rect.height, accuracy: 0.0001)
    }

    private func assertInsideUnit(_ rect: CGRect, file: StaticString = #file, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(rect.minX, -0.0001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, -0.0001, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, 1.0001, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, 1.0001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.width, 0.05 - 0.0001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.height, 0.05 - 0.0001, file: file, line: line)
    }
}
