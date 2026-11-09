import AppKit
import QuickGradeCore
import SwiftUI

struct GradeOverlay: View {
    @Bindable var session: GradeSession
    @State private var hovering = false
    @State private var compareDownAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(WindowDragCatcher())
                .zIndex(1)
            HStack(spacing: 0) {
                imageStage
                    .clipShape(RoundedRectangle(cornerRadius: session.isFullScreen ? 0 : 10, style: .continuous))
                    .padding(.leading, session.isFullScreen ? 0 : 8)
                    .padding(.bottom, session.isFullScreen ? 0 : 8)
                shelf
                    .frame(width: 340)
            }
        }
        .background {
            if session.isFullScreen {
                Color.black
            } else {
                // Frosted glass, kept dark so the photo still reads true.
                GlassBackground()
                    .overlay(Color.black.opacity(0.28))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: session.isFullScreen ? 0 : 16, style: .continuous)
                .stroke(Color.white.opacity(session.isFullScreen ? 0 : 0.1), lineWidth: 1)
        )
        .ignoresSafeArea()
        .onHover { hovering = $0 }
    }

    private var imageStage: some View {
        ZStack {
            Color.black.opacity(session.isFullScreen ? 1 : 0.72)
            photo
            if !session.cropping && !session.drawing {
                // Press and hold the photo to see the original, like holding the compare button.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if session.isDirty && !session.originalHeld { session.setCompareHeld(true) }
                            }
                            .onEnded { _ in session.setCompareHeld(false) }
                    )
                    .contextMenu { Button("Copy") { session.copyImage() } }
            }

            VStack {
                Spacer()
                    .allowsHitTesting(false)
                if let hud = session.hud {
                    hudView(hud)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if let notice = session.notice {
                    badge(notice)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 6) {
                if session.showingOriginal {
                    badge("Original")
                }
                if session.showClipping && !session.cropping && !session.drawing {
                    badge("Clipping shown · J to hide")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
            .allowsHitTesting(false)

            if hovering {
                HStack {
                    if session.canGoBack {
                        sideButton("chevron.left") { session.go(by: -1) }
                    }
                    Spacer()
                    if session.canGoForward {
                        sideButton("chevron.right") { session.go(by: 1) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(WindowDragCatcher())
        .onChange(of: session.fileName) { _, _ in
            session.zoom = 1
            session.pan = .zero
        }
        .onChange(of: session.cropping) { _, _ in
            session.zoom = 1
            session.pan = .zero
        }
        .onChange(of: session.drawing) { _, _ in
            session.zoom = 1
            session.pan = .zero
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: session.hud)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: session.notice)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: session.showingOriginal)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: session.showClipping)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            WindowLights(
                fullScreen: session.isFullScreen,
                onClose: { session.close() },
                onFullScreen: { session.toggleFullScreen() }
            )
            .padding(.trailing, 4)
            FileTitle(session: session)
                .layoutPriority(-1)
            Spacer(minLength: 12)

            ToolbarButton(symbol: "crop", title: "Crop & Straighten", shortcut: "C", on: session.cropping) {
                session.toggleCrop()
            }
            ToolbarButton(symbol: "pencil", title: "Draw", shortcut: "D", on: session.drawing) {
                session.toggleDrawing()
            }
            compareButton
            separator
            ToolbarButton(symbol: "arrow.uturn.backward", title: undoTitle, shortcut: "⌘Z", enabled: session.canUndo) {
                session.undo()
            }
            ToolbarButton(symbol: "arrow.uturn.forward", title: "Redo", shortcut: "⇧⌘Z", enabled: session.canRedo) {
                session.redo()
            }
            separator
            ShareButton(session: session)
            optionsMenu
        }
    }

    private var undoTitle: String {
        let name = session.undoManager.undoActionName
        return name.isEmpty ? "Undo" : "Undo \(name)"
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private var compareButton: some View {
        ToolbarGlyph(symbol: "square.split.2x1", on: session.showingOriginal)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if compareDownAt == nil {
                            compareDownAt = Date()
                            session.setCompareHeld(true)
                        }
                    }
                    .onEnded { _ in
                        let short = Date().timeIntervalSince(compareDownAt ?? .distantPast) < 0.2
                        session.setCompareHeld(false)
                        if short { session.toggleCompareLock() }
                        compareDownAt = nil
                    }
            )
            .modifier(HoverTip(title: "Before & After. Hold to peek, click to keep", shortcut: "\\"))
            .accessibilityLabel("Before and After")
    }

    private var optionsMenu: some View {
        Menu {
            Button("Export a Copy…") { session.save() }
                .keyboardShortcut("s")
                .disabled(!session.isDirty || session.isSaving)
            Button("Copy Image") { session.copyImage() }
                .keyboardShortcut("c")
            Divider()
            Button("Copy Adjustments") { session.copyAdjustments() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Adjustments") { session.pasteAdjustments() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!session.canPaste)
            Divider()
            Toggle("Show Clipping", isOn: Binding(
                get: { session.showClipping },
                set: { _ in session.toggleClipping() }
            ))
            .keyboardShortcut("j", modifiers: [])
            Divider()
            Button("Revert \(session.page.title)") { session.resetPage() }
                .disabled(session.settings.isPageNeutral(session.page))
            Button("Revert to Original") { session.resetAll() }
                .disabled(!session.isDirty)
        } label: {
            ToolbarGlyph(symbol: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(HoverTip(title: "More", shortcut: nil, alignment: .topTrailing))
        .accessibilityLabel("More")
    }

    private var shelf: some View {
        Group {
            if session.drawing {
                MarkupShelf(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if session.cropping {
                CropShelf(
                    edit: cropBinding,
                    imageAspect: session.sourceAspect,
                    interacting: cropInteracting
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                gradeShelf
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.cropping)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.drawing)
    }

    private var cropBinding: Binding<CropEdit> {
        Binding(
            get: {
                var shown = session.settings.crop
                shown.rect = session.cropFrame
                return shown
            },
            set: { updated in
                session.cropFrame = updated.rect
                let covered = CropGeometry.imageRect(
                    covering: updated.rect,
                    zoom: session.zoom,
                    pan: session.pan,
                    viewSize: session.cropViewSize
                )
                session.setCrop(updated.replacing(rect: covered))
            }
        )
    }

    private var cropInteracting: Binding<Bool> {
        Binding(get: { session.cropInteracting }, set: { session.cropInteracting = $0 })
    }

    @ViewBuilder
    private var photo: some View {
        if session.cropping, let image = session.displayedImage {
            GeometryReader { geo in
                let aspect = CropGeometry.displayAspect(edit: session.settings.crop, imageAspect: session.sourceAspect)
                let fitted = fittedSize(aspect: aspect, maxWidth: geo.size.width - 40, maxHeight: geo.size.height - 52)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(session.zoom)
                        .offset(session.pan)
                        .allowsHitTesting(false)
                    CropCanvas(
                        edit: cropBinding,
                        imageAspect: session.sourceAspect,
                        interacting: cropInteracting
                    )
                    .frame(width: fitted.width, height: fitted.height)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { session.rememberCropView(fitted) }
                .onChange(of: geo.size) { _, _ in session.rememberCropView(fitted) }
                .contextMenu { Button("Copy") { session.copyImage() } }
            }
        } else if session.drawing, let image = session.displayedImage {
            GeometryReader { geo in
                let aspect = max(image.size.width / max(image.size.height, 1), 0.01)
                let fitted = fittedSize(aspect: aspect, maxWidth: geo.size.width - 40, maxHeight: geo.size.height - 52)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                    MarkupCanvas(session: session)
                        .frame(width: fitted.width, height: fitted.height)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contextMenu { Button("Copy") { session.copyImage() } }
            }
        } else if let image = session.displayedImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .overlay {
                    if !session.showingOriginal && !session.settings.markup.isEmpty {
                        MarkupLayer(strokes: session.settings.markup)
                    }
                }
                .padding(16)
                .scaleEffect(session.zoom)
                .offset(session.pan)
                .allowsHitTesting(false)
                .animation(nil, value: session.showingOriginal)
                .contextMenu { Button("Copy") { session.copyImage() } }
        }
    }

    private func fittedSize(aspect: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let safe = max(aspect, 0.01)
        var width = max(maxWidth, 1)
        var height = width / safe
        if height > max(maxHeight, 1) {
            height = max(maxHeight, 1)
            width = height * safe
        }
        return CGSize(width: width, height: height)
    }

    private var gradeShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(GradePage.allCases) { page in
                    let selected = session.page == page
                    Button {
                        session.page = page
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Text(page.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                        .background(
                            selected ? Color.white.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(page.subtitle)
                }
            }
            ScrollView {
                Group {
                    switch session.page {
                    case .light:
                        sliderColumn(GradeSettings.lightControls)
                    case .whiteBalance:
                        sliderColumn(GradeSettings.whiteBalanceControls)
                    case .hsl:
                        hslPage
                    case .style:
                        stylePage
                    case .curves:
                        CurveEditor(session: session)
                    case .filters:
                        FilterShelf(session: session)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .id(session.page)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.page)
    }

    private var stylePage: some View {
        VStack(alignment: .leading, spacing: 4) {
            sliderColumn(GradeSettings.styleControls)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grain")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                Text("How much grain sits in dark, middle, and light tones")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
            .padding(.leading, 6)
            sliderColumn(GradeSettings.grainControls)
        }
    }

    private var hslPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(HSLBand.allCases) { band in
                    let rgb = band.rgb
                    let selected = session.selectedBand == band
                    Button {
                        session.selectedBand = band
                    } label: {
                        Circle()
                            .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                            .frame(width: selected ? 22 : 16, height: selected ? 22 : 16)
                            .overlay(
                                Circle().stroke(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 2)
                            )
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(band.title)
                }
                Text(session.selectedBand.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.leading, 4)
            }
            VStack(spacing: 2) {
                ForEach(GradeSettings.hslControls, id: \.name) { control in
                    ValueSlider(
                        name: control.name,
                        symbol: control.symbol,
                        range: -100...100,
                        baseline: 0,
                        bipolar: true,
                        display: .signedHundred,
                        value: session.hslValue(control.keyPath),
                        onBegin: { session.beginHSLEdit() },
                        onChange: { session.setHSL(control.keyPath, to: $0) },
                        onEnd: { session.endEdit() }
                    )
                }
            }
        }
    }

    private func sliderColumn(_ controls: [ControlSpec]) -> some View {
        VStack(spacing: 1) {
            ForEach(controls) { spec in
                ValueSlider(
                    name: spec.name,
                    symbol: spec.symbol,
                    range: spec.range,
                    baseline: spec.baseline,
                    bipolar: spec.bipolar,
                    display: spec.display,
                    value: session.value(for: spec.keyPath),
                    onBegin: { session.beginEdit(action: spec.name) },
                    onChange: { newValue in
                        session.set(spec.keyPath, to: newValue)
                        session.showHUD(symbol: spec.symbol, name: spec.name, value: spec.format(newValue))
                    },
                    onEnd: { session.endEdit() }
                )
            }
        }
    }

    private func hudView(_ hud: ControlHUD) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hud.symbol)
            Text(hud.name)
            Text(hud.value)
                .monospacedDigit()
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private func sideButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The shelf is a panel in a background app. Without this the glass turns flat grey.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WindowDragCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

private final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
