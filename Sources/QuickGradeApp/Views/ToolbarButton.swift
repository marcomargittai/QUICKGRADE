import SwiftUI

/// Round toolbar button. A label with the name and shortcut shows quickly on hover,
/// instead of the system tooltip that takes a few seconds.
struct ToolbarButton: View {
    let symbol: String
    let title: String
    var shortcut: String?
    var on = false
    var enabled = true
    var tipAlignment: Alignment = .top
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarGlyph(symbol: symbol, on: on, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(HoverTip(title: title, shortcut: shortcut, alignment: tipAlignment))
        .accessibilityLabel(title)
    }
}

struct ToolbarGlyph: View {
    let symbol: String
    var on = false
    var enabled = true
    @State private var hovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(on ? Color.black : Color.white.opacity(enabled ? 0.92 : 0.28))
            .frame(width: 30, height: 30)
            .background(
                on ? Color.white : Color.white.opacity(hovered && enabled ? 0.16 : 0.08),
                in: Circle()
            )
            .contentShape(Circle())
            .onHover { hovered = $0 }
            .animation(.snappy(duration: 0.15), value: on)
            .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

struct HoverTip: ViewModifier {
    let title: String
    let shortcut: String?
    var alignment: Alignment = .top

    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded { shown = false })
            .overlay(alignment: alignment) {
                if shown {
                    tip
                        .fixedSize()
                        .offset(y: 40)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: shown)
    }

    private var tip: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.white)
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(white: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
