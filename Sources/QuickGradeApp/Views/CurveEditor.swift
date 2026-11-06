import AppKit
import QuickGradeCore
import SwiftUI

struct CurveEditor: View {
    var session: GradeSession

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(CurveChannel.allCases) { channel in
                    let selected = session.curveChannel == channel
                    let color = channelColor(channel)
                    Button {
                        session.curveChannel = channel
                    } label: {
                        Text(channel.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.white.opacity(0.7))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(selected ? color : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !session.settings.curves[session.curveChannel].isIdentity {
                    Button("Reset") {
                        session.beginCurveEdit()
                        session.setCurve(ToneCurve.identity.points)
                        session.endEdit()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            CurveCanvas(session: session)
                .frame(height: 188)
        }
    }

    private func channelColor(_ channel: CurveChannel) -> Color {
        let rgb = channel.rgb
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

private struct CurveCanvas: View {
    var session: GradeSession
    @State private var dragID: UUID?
    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .gesture(drag(in: size))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                removePoint(at: value.location, size: size)
            })
        }
    }

    private var points: [CurvePoint] {
        CurveMath.sanitized(session.settings.curves[session.curveChannel].points)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragID == nil {
                    session.beginCurveEdit()
                    moved = false
                    if let hit = hitPoint(at: value.startLocation, size: size) {
                        dragID = hit
                    } else if nearCurve(value.startLocation, size: size) {
                        let placed = plotPoint(value.startLocation, size: size)
                        var next = points
                        let created = CurvePoint(x: placed.x, y: placed.y)
                        next.append(created)
                        session.setCurve(next)
                        dragID = created.id
                    } else {
                        return
                    }
                }
                guard let dragID else { return }
                moved = moved || hypot(value.translation.width, value.translation.height) > 2
                var next = points
                guard let index = next.firstIndex(where: { $0.id == dragID }) else { return }
                let plotted = plotPoint(value.location, size: size)
                let endpoint = index == 0 || index == next.count - 1
                next[index].x = endpoint ? (index == 0 ? 0 : 1) : plotted.x
                next[index].y = plotted.y
                session.setCurve(next)
            }
            .onEnded { _ in
                dragID = nil
                session.endEdit()
            }
    }

    private func removePoint(at location: CGPoint, size: CGSize) {
        guard let id = hitPoint(at: location, size: size) else { return }
        let current = points
        guard current.count > 2, let index = current.firstIndex(where: { $0.id == id }), index != 0, index != current.count - 1 else {
            return
        }
        session.beginCurveEdit()
        session.setCurve(current.filter { $0.id != id })
        session.endEdit()
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let plot = plotRect(size)
        context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.white.opacity(0.04)))

        let histogram = session.curveChannel == .rgb ? session.displayedHistogram.luma : channelBins()
        if !histogram.isEmpty {
            var bars = Path()
            let count = histogram.count
            let step = plot.width / CGFloat(count)
            for (index, value) in histogram.enumerated() {
                let h = CGFloat(value) * plot.height
                let x = plot.minX + CGFloat(index) * step
                bars.addRect(CGRect(x: x, y: plot.maxY - h, width: max(step - 0.4, 0.4), height: h))
            }
            context.fill(bars, with: .color(strokeColor.opacity(0.18)))
        }

        var grid = Path()
        for step in 1..<4 {
            let t = CGFloat(step) / 4
            grid.move(to: CGPoint(x: plot.minX + plot.width * t, y: plot.minY))
            grid.addLine(to: CGPoint(x: plot.minX + plot.width * t, y: plot.maxY))
            grid.move(to: CGPoint(x: plot.minX, y: plot.minY + plot.height * t))
            grid.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + plot.height * t))
        }
        context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: viewPoint(x: 0, y: 0, plot: plot))
        diagonal.addLine(to: viewPoint(x: 1, y: 1, plot: plot))
        context.stroke(diagonal, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

        let samples = CurveMath.samples(points: points, count: 64)
        var curve = Path()
        for (index, sample) in samples.enumerated() {
            let x = Double(index) / Double(samples.count - 1)
            let point = viewPoint(x: x, y: sample, plot: plot)
            if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(strokeColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        for point in points {
            let center = viewPoint(x: point.x, y: point.y, plot: plot)
            let dot = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot), with: .color(.white))
            context.stroke(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(strokeColor), lineWidth: 1.5)
        }
    }

    private func channelBins() -> [Float] {
        switch session.curveChannel {
        case .rgb: return session.displayedHistogram.luma
        case .red: return session.displayedHistogram.red
        case .green: return session.displayedHistogram.green
        case .blue: return session.displayedHistogram.blue
        }
    }

    private var strokeColor: Color {
        let rgb = session.curveChannel.rgb
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24)
    }

    private func viewPoint(x: Double, y: Double, plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + CGFloat(x) * plot.width,
            y: plot.maxY - CGFloat(y) * plot.height
        )
    }

    private func plotPoint(_ location: CGPoint, size: CGSize) -> (x: Double, y: Double) {
        let plot = plotRect(size)
        let x = Double((location.x - plot.minX) / plot.width)
        let y = Double((plot.maxY - location.y) / plot.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func hitPoint(at location: CGPoint, size: CGSize) -> UUID? {
        let plot = plotRect(size)
        var best: (UUID, CGFloat)?
        for point in points {
            let center = viewPoint(x: point.x, y: point.y, plot: plot)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance < 14, best == nil || distance < best!.1 {
                best = (point.id, distance)
            }
        }
        return best?.0
    }

    private func nearCurve(_ location: CGPoint, size: CGSize) -> Bool {
        let plot = plotRect(size)
        let samples = CurveMath.samples(points: points, count: 48)
        for (index, sample) in samples.enumerated() {
            let x = Double(index) / Double(samples.count - 1)
            let center = viewPoint(x: x, y: sample, plot: plot)
            if hypot(center.x - location.x, center.y - location.y) < 12 { return true }
        }
        return false
    }
}
