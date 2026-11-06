import QuickGradeCore
import SwiftUI

public struct SelectionShelf: View {
    public var brush: Binding<CGFloat>
    public var erasing: Binding<Bool>
    public var reach: Binding<CGFloat>
    public var canApply: Bool
    public var applying: Bool
    public var onApply: () -> Void
    public var onClear: () -> Void
    public var onReachEdit: (Bool) -> Void

    public init(
        brush: Binding<CGFloat>,
        erasing: Binding<Bool>,
        reach: Binding<CGFloat>,
        canApply: Bool,
        applying: Bool,
        onApply: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onReachEdit: @escaping (Bool) -> Void
    ) {
        self.brush = brush
        self.erasing = erasing
        self.reach = reach
        self.canApply = canApply
        self.applying = applying
        self.onApply = onApply
        self.onClear = onClear
        self.onReachEdit = onReachEdit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if !canApply {
                    Text("Mark what should stay")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                brushRow
                reachRow
                toolRow
            }
            actions
                .padding(.top, 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 340, alignment: .topLeading)
    }

    private var brushRow: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.2)
                .frame(width: 12, height: 12)
            Slider(value: brush, in: 6...72)
                .tint(Color.white)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    private var reachRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reach")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, 6)
            Slider(value: reach, in: 0...1) { editing in
                onReachEdit(editing)
            }
            .tint(Color.white)
            .disabled(applying)
            .padding(.horizontal, 6)
        }
        .help("How far the selection spreads from the marker")
    }

    private var toolRow: some View {
        HStack(spacing: 10) {
            toolButton("pencil.tip", selected: !erasing.wrappedValue) {
                erasing.wrappedValue = false
            }
            toolButton("eraser", selected: erasing.wrappedValue) {
                erasing.wrappedValue = true
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onApply) {
                Text(applying ? "Applying" : "Apply")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canApply || applying)
            .opacity(!canApply || applying ? 0.4 : 1)

            Button("Clear", action: onClear)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .disabled(!canApply)
        }
    }

    private func toolButton(_ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(selected ? Color.white.opacity(0.18) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

public struct SelectionCanvas: View {
    @Binding public var strokes: [SelectionStroke]
    public var brush: CGFloat
    public var erasing: Bool

    @State private var draft: [CGPoint] = []
    @State private var pointer: CGPoint?

    public init(strokes: Binding<[SelectionStroke]>, brush: CGFloat, erasing: Bool) {
        self._strokes = strokes
        self.brush = brush
        self.erasing = erasing
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(drag(in: size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                case .ended:
                    pointer = nil
                }
            }
        }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                pointer = value.location
                let point = normalized(value.location, in: size)
                if draft.isEmpty {
                    draft = [point]
                } else if draft.last != point {
                    draft.append(point)
                }
            }
            .onEnded { _ in
                if !draft.isEmpty {
                    strokes.append(SelectionStroke(
                        points: draft,
                        radius: brush / max(size.width, 1),
                        erases: erasing
                    ))
                }
                draft = []
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        context.drawLayer { layer in
            for stroke in displayStrokes(in: size) {
                paint(stroke, in: &layer, size: size)
            }
        }
        if let pointer {
            let radius = brush / 2
            let ring = CGRect(
                x: pointer.x - radius,
                y: pointer.y - radius,
                width: brush,
                height: brush
            )
            context.stroke(Path(ellipseIn: ring), with: .color(.red), lineWidth: 1)
        }
    }

    private func displayStrokes(in size: CGSize) -> [SelectionStroke] {
        guard !draft.isEmpty else { return strokes }
        return strokes + [
            SelectionStroke(points: draft, radius: brush / max(size.width, 1), erases: erasing)
        ]
    }

    private func paint(_ stroke: SelectionStroke, in context: inout GraphicsContext, size: CGSize) {
        let radius = stroke.radius * size.width
        let points = stroke.points.map { viewPoint($0, in: size) }
        var path = Path()
        if points.count == 1, let point = points.first {
            path.addEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            if stroke.erases {
                context.blendMode = .destinationOut
                context.fill(path, with: .color(.white))
            } else {
                context.blendMode = .normal
                context.fill(path, with: .color(.red.opacity(0.45)))
            }
            return
        }
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        let style = StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round)
        if stroke.erases {
            context.blendMode = .destinationOut
            context.stroke(path, with: .color(.white), style: style)
        } else {
            context.blendMode = .normal
            context.stroke(path, with: .color(.red.opacity(0.45)), style: style)
        }
    }

    private func viewPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(size.width, 1), 0), 1),
            y: min(max(point.y / max(size.height, 1), 0), 1)
        )
    }
}
