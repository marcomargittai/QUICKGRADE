import AppKit
import SwiftUI

/// Close and full screen, where macOS puts them. Glyphs show on hover, like the system buttons.
struct WindowLights: View {
    let fullScreen: Bool
    let onClose: () -> Void
    let onFullScreen: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(color: Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark", title: "Close", shortcut: "Space", action: onClose)
            light(
                color: Color(red: 0.16, green: 0.79, blue: 0.25),
                symbol: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                title: fullScreen ? "Exit Full Screen" : "Full Screen",
                shortcut: "F",
                action: onFullScreen
            )
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func light(color: Color, symbol: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .opacity(hovering ? 1 : 0)
                }
                .frame(width: 13, height: 13)
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .modifier(HoverTip(title: title, shortcut: shortcut, alignment: .topLeading))
        .accessibilityLabel(title)
    }
}

/// The file name. Click it to rename the file, like a title in Finder or Preview.
struct FileTitle: View {
    @Bindable var session: GradeSession
    @State private var hovered = false

    var body: some View {
        Group {
            if session.renaming {
                RenameField(
                    name: session.fileName,
                    onCommit: { name in
                        session.renaming = false
                        session.rename(to: name)
                    },
                    onCancel: { session.renaming = false }
                )
                .frame(minWidth: 160, maxWidth: 360)
                .frame(height: 24)
            } else {
                HStack(spacing: 6) {
                    Text(session.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if session.isDirty {
                        Circle()
                            .fill(Color.white.opacity(0.7))
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Edited")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    Color.white.opacity(hovered ? 0.1 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .onTapGesture { session.renaming = true }
                .modifier(HoverTip(title: "Click to rename", shortcut: nil))
                .animation(.easeOut(duration: 0.1), value: hovered)
            }
        }
    }
}

/// Text field that opens with the name selected up to the extension, as Finder does.
/// Return renames, Escape or clicking away keeps the old name.
struct RenameField: NSViewRepresentable {
    let name: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .white
        field.backgroundColor = NSColor(white: 0.18, alpha: 1)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingMiddle
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            let stem = (name as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        private var finished = false

        init(_ parent: RenameField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: control.stringValue)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: nil)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish(commit: nil)
        }

        private func finish(commit name: String?) {
            guard !finished else { return }
            finished = true
            if let name { parent.onCommit(name) } else { parent.onCancel() }
        }
    }
}
