import AppKit
import QuickGradeCore
import SwiftUI

/// Finished strokes over the photo. Same frame as the image view, so it scales and pans with it.
struct MarkupLayer: View {
    let strokes: [MarkupStroke]

    var body: some View {
        Canvas { context, size in
            for stroke in strokes {
                MarkupPainter.paint(stroke, in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
    }
}

enum MarkupPainter {
    static func paint(_ stroke: MarkupStroke, in context: inout GraphicsContext, size: CGSize, opacity: Double = 1) {
        let rgb = stroke.color.rgb
        context.stroke(
            Path(Markup.path(stroke.points, in: size)),
            with: .color(Color(red: rgb.0, green: rgb.1, blue: rgb.2).opacity(opacity)),
            style: StrokeStyle(lineWidth: Markup.lineWidth(stroke, in: size), lineCap: .round, lineJoin: .round)
        )
    }
}

/// Where the pen and eraser work. Sized to the photo.
struct MarkupCanvas: View {
    @Bindable var session: GradeSession

    @State private var draft: [CGPoint] = []
    @State private var hover: CGPoint?
    @State private var erasing = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, size in
                for stroke in session.settings.markup {
                    MarkupPainter.paint(stroke, in: &context, size: size)
                }
                if !draft.isEmpty {
                    MarkupPainter.paint(draftStroke, in: &context, size: size)
                }
            }
            .overlay { cursor(in: size) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in drag(to: value.location, in: size) }
                    .onEnded { _ in finish() }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hover = point
                case .ended: hover = nil
                }
            }
        }
    }

    private var draftStroke: MarkupStroke {
        MarkupStroke(points: draft, width: session.markupSize.width, color: session.markupColor)
    }

    @ViewBuilder
    private func cursor(in size: CGSize) -> some View {
        if let hover {
            let diameter = session.erasingMarkup
                ? 22
                : max(CGFloat(session.markupSize.width) * max(size.width, size.height), 4)
            let rgb = session.markupColor.rgb
            Circle()
                .fill(session.erasingMarkup ? Color.white.opacity(0.12) : Color(red: rgb.0, green: rgb.1, blue: rgb.2).opacity(0.35))
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 1)
                .frame(width: diameter, height: diameter)
                .position(hover)
                .allowsHitTesting(false)
        }
    }

    private func drag(to location: CGPoint, in size: CGSize) {
        hover = location
        let point = CGPoint(
            x: min(max(location.x / max(size.width, 1), 0), 1),
            y: min(max(location.y / max(size.height, 1), 0), 1)
        )
        if session.erasingMarkup {
            if !erasing {
                erasing = true
                session.beginErase()
            }
            session.erase(at: point, aspect: size.width / max(size.height, 1))
            return
        }
        // Skip points closer than a pixel. The curve between midpoints stays smooth without them.
        if let last = draft.last {
            let dx = (point.x - last.x) * size.width
            let dy = (point.y - last.y) * size.height
            guard dx * dx + dy * dy >= 1 else { return }
        }
        draft.append(point)
    }

    private func finish() {
        if erasing {
            erasing = false
            session.endEdit()
            return
        }
        guard !draft.isEmpty else { return }
        session.addMarkup(draftStroke)
        draft = []
    }
}

/// Side panel while drawing.
struct MarkupShelf: View {
    @Bindable var session: GradeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Draw")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Draw right on the photo. It stays with your edits and shows in Finder.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            toolPicker

            section("Color") {
                HStack(spacing: 10) {
                    ForEach(MarkupColor.allCases) { color in
                        let selected = session.markupColor == color && !session.erasingMarkup
                        let rgb = color.rgb
                        Button {
                            session.markupColor = color
                            session.erasingMarkup = false
                        } label: {
                            Circle()
                                .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                                .overlay(Circle().stroke(Color.white.opacity(color == .black ? 0.35 : 0), lineWidth: 1))
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().stroke(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.title)
                        .animation(.snappy(duration: 0.15), value: selected)
                    }
                }
            }

            section("Size") {
                HStack(spacing: 8) {
                    ForEach(MarkupSize.allCases) { size in
                        let selected = session.markupSize == size
                        Button {
                            session.markupSize = size
                            session.erasingMarkup = false
                        } label: {
                            Circle()
                                .fill(Color.white)
                                .frame(width: dot(size), height: dot(size))
                                .frame(width: 44, height: 32)
                                .background(
                                    selected ? Color.white.opacity(0.16) : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(size.title)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    session.clearMarkup()
                } label: {
                    Text("Clear All")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShelfButtonStyle(prominent: false))
                .disabled(session.settings.markup.isEmpty)

                Button {
                    session.toggleDrawing()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShelfButtonStyle(prominent: true))
            }

            Text("E switches pen and eraser. ⌘Z takes back the last stroke.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340, alignment: .topLeading)
    }

    private var toolPicker: some View {
        HStack(spacing: 2) {
            toolButton("Pen", symbol: "pencil.tip", selected: !session.erasingMarkup) {
                session.erasingMarkup = false
            }
            toolButton("Eraser", symbol: "eraser", selected: session.erasingMarkup) {
                session.erasingMarkup = true
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toolButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    selected ? Color.white : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: selected)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
            content()
        }
    }

    private func dot(_ size: MarkupSize) -> CGFloat {
        switch size {
        case .fine: return 4
        case .medium: return 8
        case .bold: return 14
        }
    }
}

struct ShelfButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(isEnabled ? 0.9 : 0.3))
            .padding(.vertical, 8)
            .background(
                prominent ? Color.white.opacity(configuration.isPressed ? 0.8 : 1) : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}
