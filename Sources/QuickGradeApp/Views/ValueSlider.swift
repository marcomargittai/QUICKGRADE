import AppKit
import QuickGradeCore
import SwiftUI

struct ValueSlider: View {
    let name: String
    let symbol: String
    let range: ClosedRange<Double>
    let baseline: Double
    let bipolar: Bool
    let display: ValueDisplay
    let value: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var dragValue: Double?
    @State private var startValue: Double = 0
    @State private var snapped = false
    @State private var hovered = false
    @State private var scrollEnd: Task<Void, Never>?

    private var shown: Double { dragValue ?? value }
    private var awayFromBaseline: Bool { abs(shown - baseline) > 0.000_001 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(awayFromBaseline ? Color.white.opacity(0.92) : Color.white.opacity(0.42))
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, weight: awayFromBaseline ? .semibold : .medium))
                .foregroundStyle(awayFromBaseline ? Color.white.opacity(0.94) : Color.white.opacity(0.62))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            track
            Text(format(shown))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { hovered = $0 }
        .background(ScrollMonitor(enabled: hovered, onScroll: scroll))
        .overlay(SliderDragCatcher(onEvent: handleDrag))
        .help("Double-click to reset. Shift-drag or shift-scroll for a finer step.")
    }

    private var track: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 3)
                if bipolar {
                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 1, height: 8)
                }
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(fillWidth(width), 0), height: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: fillOrigin(width))
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                    .scaleEffect(snapped ? 1.2 : (hovered ? 1.06 : 1))
                    .position(x: thumbX(width), y: geo.size.height / 2)
                    .animation(.snappy(duration: 0.16), value: snapped)
            }
            .contentShape(Rectangle())
            .animation(dragValue == nil ? .snappy(duration: 0.22) : nil, value: shown)
        }
        .frame(height: 18)
    }

    private func handleDrag(_ event: SliderDragEvent) {
        switch event {
        case .begin:
            startValue = value
            onBegin()
        case .change(let x, let translation, let width, let shift):
            let span = range.upperBound - range.lowerBound
            if shift {
                publish(startValue + Double(translation) / Double(max(width, 1)) * span * 0.16)
            } else {
                let clamped = min(max(x, 0), width)
                publish(range.lowerBound + Double(clamped / max(width, 1)) * span)
            }
        case .end:
            dragValue = nil
            snapped = false
            onEnd()
        case .reset:
            reset()
        }
    }

    private func scroll(_ delta: CGFloat) {
        if dragValue == nil { onBegin() }
        let span = range.upperBound - range.lowerBound
        let fine: Double = NSEvent.modifierFlags.contains(.shift) ? 0.28 : 1
        publish(shown + Double(delta) * span * 0.0015 * fine)
        scrollEnd?.cancel()
        scrollEnd = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            dragValue = nil
            snapped = false
            onEnd()
        }
    }

    private func publish(_ raw: Double) {
        let next = snap(raw)
        dragValue = next
        onChange(next)
    }

    private func snap(_ raw: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        let zone = max((range.upperBound - range.lowerBound) * 0.018, display == .exposure ? 0.04 : 1.6)
        if abs(clamped - baseline) <= zone {
            if !snapped {
                snapped = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            return baseline
        }
        snapped = false
        return clamped
    }

    private func reset() {
        onBegin()
        dragValue = nil
        snapped = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onChange(baseline)
        onEnd()
    }

    private func thumbX(_ width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let t = span == 0 ? 0 : (shown - range.lowerBound) / span
        return CGFloat(min(max(t, 0), 1)) * width
    }

    private func fillOrigin(_ width: CGFloat) -> CGFloat {
        guard bipolar else { return 0 }
        return min(thumbX(width), width / 2)
    }

    private func fillWidth(_ width: CGFloat) -> CGFloat {
        if bipolar { return abs(thumbX(width) - width / 2) }
        return thumbX(width)
    }

    private func format(_ value: Double) -> String {
        if abs(value - baseline) < 0.000_001 { return "0" }
        switch display {
        case .exposure: return String(format: "%+.2f", value)
        case .signedHundred: return String(format: "%+.0f", value)
        case .unsignedHundred: return String(format: "%.0f", value)
        }
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    var enabled: Bool
    var onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onScroll = onScroll
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: MarkerView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var enabled = false
        var onScroll: (CGFloat) -> Void
        weak var view: MarkerView?
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func install(on view: MarkerView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let view = self.view, let window = view.window, event.window == window else {
                    return event
                }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                self.onScroll(event.scrollingDeltaY)
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private final class MarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}


enum SliderDragEvent {
    case begin
    case change(x: CGFloat, translation: CGFloat, width: CGFloat, shift: Bool)
    case end
    case reset
}

struct SliderDragCatcher: NSViewRepresentable {
    var onEvent: (SliderDragEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeNSView(context: Context) -> SliderDragView {
        let view = SliderDragView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SliderDragView, context: Context) {
        context.coordinator.onEvent = onEvent
        nsView.coordinator = context.coordinator
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SliderDragView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator {
        var onEvent: (SliderDragEvent) -> Void
        init(onEvent: @escaping (SliderDragEvent) -> Void) { self.onEvent = onEvent }
    }
}

final class SliderDragView: NSView {
    weak var coordinator: SliderDragCatcher.Coordinator?
    private let trackOrigin: CGFloat = 6 + 16 + 8 + 84 + 8
    private let trackTail: CGFloat = 6 + 42 + 8

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= trackOrigin - 8, point.x <= bounds.width - trackTail + 8 else {
            window?.performDrag(with: event)
            return
        }
        if event.clickCount >= 2 {
            coordinator?.onEvent(.reset)
            return
        }
        let originX = point.x
        coordinator?.onEvent(.begin)
        emit(point.x, translation: 0, shift: event.modifierFlags.contains(.shift))
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let next = window?.nextEvent(matching: mask) {
            let location = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                coordinator?.onEvent(.end)
                break
            }
            emit(location.x, translation: location.x - originX, shift: next.modifierFlags.contains(.shift))
        }
    }

    private func emit(_ x: CGFloat, translation: CGFloat, shift: Bool) {
        let width = max(bounds.width - trackOrigin - trackTail, 1)
        let local = min(max(x - trackOrigin, 0), width)
        coordinator?.onEvent(.change(x: local, translation: translation, width: width, shift: shift))
    }
}
