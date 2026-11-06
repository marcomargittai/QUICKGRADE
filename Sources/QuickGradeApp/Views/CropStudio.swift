import AppKit
import QuickGradeCore
import SwiftUI

public struct CropShelf: View {
    @Binding public var edit: CropEdit
    public var imageAspect: CGFloat
    public var interacting: Binding<Bool>?

    @State private var draggingStraighten = false

    public init(edit: Binding<CropEdit>, imageAspect: CGFloat, interacting: Binding<Bool>? = nil) {
        self._edit = edit
        self.imageAspect = imageAspect
        self.interacting = interacting
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            aspectChips
            straightenRow
            toolRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 340, alignment: .topLeading)
    }

    private var aspectChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CropAspect.allCases) { aspect in
                    let selected = edit.aspect == aspect
                    Button {
                        if selected, aspect != .free, aspect != .square {
                            edit = edit.swappedSides(imageAspect: imageAspect)
                        } else {
                            edit = edit.locked(to: aspect, imageAspect: imageAspect)
                        }
                    } label: {
                        Text(selected ? aspect.title(matching: edit.resolvedPixelRatio(imageAspect: imageAspect)) : aspect.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.48))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selected ? Color.white.opacity(0.14) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var straightenRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "angle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(abs(edit.straighten) > 0.01 ? Color.white.opacity(0.92) : Color.white.opacity(0.42))
                .frame(width: 16)
                .onTapGesture(count: 2, perform: resetStraighten)
            Slider(
                value: Binding(
                    get: { edit.straighten },
                    set: { edit = edit.straightened($0, imageAspect: imageAspect) }
                ),
                in: -45...45
            ) { editing in
                draggingStraighten = editing
                interacting?.wrappedValue = editing
            }
            .tint(Color.white)
            Text(angleLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 28, alignment: .trailing)
                .onTapGesture(count: 2, perform: resetStraighten)
            Button(action: resetStraighten) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(abs(edit.straighten) > 0.01 ? Color.white.opacity(0.7) : Color.white.opacity(0.22))
            }
            .buttonStyle(.plain)
            .disabled(abs(edit.straighten) <= 0.01)
            .help("Reset straighten")
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    private var toolRow: some View {
        HStack(spacing: 10) {
            iconButton("rotate.left") {
                edit = edit.rotatedLeft()
            }
            iconButton("flip.horizontal") {
                edit = edit.flipped()
            }
            Button("Reset") {
                edit = edit.resetting()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(edit.isIdentity ? Color.white.opacity(0.28) : Color.white.opacity(0.8))
            .disabled(edit.isIdentity)
            Spacer()
        }
    }

    private var angleLabel: String {
        formatAngle(edit.straighten)
    }

    private func formatAngle(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded) < 0.5 { return "0" }
        return String(format: "%.0f", rounded)
    }

    private func resetStraighten() {
        edit = edit.straightened(0, imageAspect: imageAspect)
        draggingStraighten = false
        interacting?.wrappedValue = false
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

public struct CropCanvas: View {
    @Binding public var edit: CropEdit
    public var imageAspect: CGFloat
    public var interacting: Binding<Bool>?

    @State private var dragHandle: CropHandle?
    @State private var isDragging = false
    @State private var startRect: CGRect = .zero
    @State private var startPoint: CGPoint = .zero

    public init(edit: Binding<CropEdit>, imageAspect: CGFloat, interacting: Binding<Bool>? = nil) {
        self._edit = edit
        self.imageAspect = imageAspect
        self.interacting = interacting
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
        }
    }

    private var showGrid: Bool {
        dragHandle != nil || (interacting?.wrappedValue ?? false)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragHandle = hit(at: value.startLocation, size: size)
                    startRect = edit.rect
                    startPoint = value.startLocation
                    if dragHandle != nil {
                        interacting?.wrappedValue = true
                    }
                }
                guard let handle = dragHandle else { return }
                edit = edit.replacing(rect: dragged(
                    handle: handle,
                    start: startRect,
                    to: value.location,
                    canvas: size
                ))
            }
            .onEnded { _ in
                dragHandle = nil
                isDragging = false
                interacting?.wrappedValue = false
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let crop = viewRect(edit.rect, in: size)
        var dim = Path()
        dim.addRect(CGRect(origin: .zero, size: size))
        dim.addRect(crop)
        context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

        if showGrid {
            var grid = Path()
            for step in 1...2 {
                let t = CGFloat(step) / 3
                grid.move(to: CGPoint(x: crop.minX + crop.width * t, y: crop.minY))
                grid.addLine(to: CGPoint(x: crop.minX + crop.width * t, y: crop.maxY))
                grid.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * t))
                grid.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * t))
            }
            context.stroke(grid, with: .color(.white.opacity(0.55)), lineWidth: 1)
        }

        var brackets = Path()
        let arm = min(22, min(crop.width, crop.height) * 0.28)
        addBracket(&brackets, at: CGPoint(x: crop.minX, y: crop.minY), dx: arm, dy: arm)
        addBracket(&brackets, at: CGPoint(x: crop.maxX, y: crop.minY), dx: -arm, dy: arm)
        addBracket(&brackets, at: CGPoint(x: crop.minX, y: crop.maxY), dx: arm, dy: -arm)
        addBracket(&brackets, at: CGPoint(x: crop.maxX, y: crop.maxY), dx: -arm, dy: -arm)
        context.stroke(brackets, with: .color(.white), style: StrokeStyle(lineWidth: 2.4, lineCap: .square))

        var edges = Path()
        let mid = min(16, min(crop.width, crop.height) * 0.22)
        edges.move(to: CGPoint(x: crop.midX - mid, y: crop.minY))
        edges.addLine(to: CGPoint(x: crop.midX + mid, y: crop.minY))
        edges.move(to: CGPoint(x: crop.midX - mid, y: crop.maxY))
        edges.addLine(to: CGPoint(x: crop.midX + mid, y: crop.maxY))
        edges.move(to: CGPoint(x: crop.minX, y: crop.midY - mid))
        edges.addLine(to: CGPoint(x: crop.minX, y: crop.midY + mid))
        edges.move(to: CGPoint(x: crop.maxX, y: crop.midY - mid))
        edges.addLine(to: CGPoint(x: crop.maxX, y: crop.midY + mid))
        context.stroke(edges, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineCap: .square))
    }

    private func addBracket(_ path: inout Path, at origin: CGPoint, dx: CGFloat, dy: CGFloat) {
        path.move(to: CGPoint(x: origin.x + dx, y: origin.y))
        path.addLine(to: origin)
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + dy))
    }

    private func viewRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    private func hit(at point: CGPoint, size: CGSize) -> CropHandle? {
        let crop = viewRect(edit.rect, in: size)
        let slop: CGFloat = 16
        let corners: [(CropHandle, CGPoint)] = [
            (.nw, CGPoint(x: crop.minX, y: crop.minY)),
            (.ne, CGPoint(x: crop.maxX, y: crop.minY)),
            (.sw, CGPoint(x: crop.minX, y: crop.maxY)),
            (.se, CGPoint(x: crop.maxX, y: crop.maxY))
        ]
        if let match = corners.min(by: { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }),
           hypot(match.1.x - point.x, match.1.y - point.y) < slop {
            return match.0
        }
        if abs(point.y - crop.minY) < slop && point.x > crop.minX + slop && point.x < crop.maxX - slop { return .n }
        if abs(point.y - crop.maxY) < slop && point.x > crop.minX + slop && point.x < crop.maxX - slop { return .s }
        if abs(point.x - crop.minX) < slop && point.y > crop.minY + slop && point.y < crop.maxY - slop { return .w }
        if abs(point.x - crop.maxX) < slop && point.y > crop.minY + slop && point.y < crop.maxY - slop { return .e }
        if crop.insetBy(dx: -4, dy: -4).contains(point) { return .body }
        return nil
    }

    private func dragged(handle: CropHandle, start: CGRect, to point: CGPoint, canvas: CGSize) -> CGRect {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        var basis = edit
        basis.rect = start
        let display = max(CropGeometry.displayAspect(edit: basis, imageAspect: imageAspect), 1e-8)
        let normRatio = basis.resolvedPixelRatio(imageAspect: imageAspect) / display
        return CropGeometry.draggedRect(
            start: start,
            startPoint: startPoint,
            point: point,
            canvas: canvas,
            handle: handle,
            lockRatio: shift || edit.aspect != .free,
            fromCenter: option,
            constrainAxis: shift,
            normRatio: normRatio
        )
    }
}
