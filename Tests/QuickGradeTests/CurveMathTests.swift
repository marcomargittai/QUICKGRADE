import XCTest
@testable import QuickGradeCore

final class CurveMathTests: XCTestCase {
    func testIdentityLine() {
        let points = ToneCurve.identity.points
        XCTAssertEqual(CurveMath.value(points: points, at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(CurveMath.value(points: points, at: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CurveMath.value(points: points, at: 1), 1, accuracy: 0.0001)
    }

    func testMidPeak() {
        let points = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 1),
            CurvePoint(x: 1, y: 0)
        ]
        XCTAssertEqual(CurveMath.value(points: points, at: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(CurveMath.value(points: points, at: 0), 0, accuracy: 0.0001)
        let quarter = CurveMath.value(points: points, at: 0.25)
        XCTAssertGreaterThan(quarter, 0.2)
        XCTAssertLessThan(quarter, 0.95)
    }

    func testMonotoneDoesNotOvershoot() {
        let points = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.3, y: 0.2),
            CurvePoint(x: 0.7, y: 0.8),
            CurvePoint(x: 1, y: 1)
        ]
        let samples = CurveMath.samples(points: points, count: 21)
        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample, -0.001)
            XCTAssertLessThanOrEqual(sample, 1.001)
        }
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1 + 0.02)
        }
    }
}
