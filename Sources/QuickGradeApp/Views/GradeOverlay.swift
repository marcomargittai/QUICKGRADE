import AppKit
import QuickGradeCore
import SwiftUI

struct GradeOverlay: View {
    @Bindable var session: GradeSession
    @State private var hovering = false
    @State private var compareDownAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            imageStage
            shelf
                .frame(width: 340)
        }
        .background(Color(white: 0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    private var imageStage: some View {
        ZStack {
            if session.settings.removeBackground {
                Checkerboard()
            } else {
                Color.black
            }
            photo
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            VStack {
                topBar
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
            .padding(.top, 10)

            if session.showingOriginal {
                badge("Original")
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 52)
                    .allowsHitTesting(false)
            }

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
        .onChange(of: session.selecting) { _, _ in
            session.zoom = 1
            session.pan = .zero
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: session.hud)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: session.notice)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: session.showingOriginal)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(session.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.isDirty {
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 6, height: 6)
                        .help("Adjustments are kept for this photo")
                }
            }
            .foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            if let position = session.positionText {
                Text(position)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            iconButton(
                "crop",
                on: session.cropping,
                help: "Crop"
            ) {
                session.toggleCrop()
            }
            iconButton(
                "person.and.background.dotted",
                on: session.selecting || session.settings.removeBackground,
                enabled: !session.applyingSelection,
                help: "Mark what should stay"
            ) {
                session.toggleSelection()
            }
            compareButton
            iconButton(
                session.showClipping ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                on: session.showClipping,
                help: "Clipping. Marks blown-out whites and crushed blacks (J)."
            ) {
                session.toggleClipping()
            }
            iconButton(
                "arrow.uturn.backward",
                enabled: session.canUndo,
                help: "Undo (⌘Z)"
            ) {
                session.undo()
            }
            if session.canRedo {
                iconButton(
                    "arrow.uturn.forward",
                    enabled: true,
                    help: "Redo (⇧⌘Z)"
                ) {
                    session.redo()
                }
            }
            iconButton(
                "arrow.counterclockwise",
                enabled: session.isDirty,
                help: "Revert this page. Option-click reverts the whole photo."
            ) {
                if NSEvent.modifierFlags.contains(.option) {
                    session.resetAll()
                } else {
                    session.resetPage()
                }
            }
            optionsMenu
            iconButton("xmark", help: "Close (Space or Escape)") { session.close() }
        }
    }

    private var compareButton: some View {
        Image(systemName: session.showingOriginal ? "eye.fill" : "eye")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(session.showingOriginal ? 0.18 : 0.08), in: Circle())
            .contentShape(Circle())
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
            .help("Hold to see the original. Click to keep it (\\).")
    }

    private var optionsMenu: some View {
        Menu {
            Button("Copy Adjustments") { session.copyAdjustments() }
            Button("Paste Adjustments") { session.pasteAdjustments() }
                .disabled(!session.canPaste)
            Divider()
            Button("Export a Copy") { session.save() }
                .disabled(!session.isDirty || session.isSaving)
            Button("Revert All") { session.resetAll() }
            Button("Copy Image") { session.copyImage() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy and paste the grade")
    }

    private var shelf: some View {
        Group {
            if session.selecting {
                VStack(alignment: .leading, spacing: 8) {
                    SelectionShelf(
                        brush: $session.brush,
                        erasing: $session.erasing,
                        reach: Binding(
                            get: { CGFloat(session.settings.selectionReach) },
                            set: { session.previewReach(Double($0)) }
                        ),
                        canApply: !session.strokes.isEmpty,
                        applying: session.applyingSelection,
                        onApply: { session.applySelection() },
                        onClear: { session.strokes = [] },
                        onReachEdit: { editing in
                            if editing { session.beginReach() } else { session.endReach() }
                        }
                    )
                    if session.settings.removeBackground {
                        Button("Restore background") { session.restoreBackground() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .padding(.horizontal, 12)
                    }
                }
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
        .background(session.cropping || session.selecting ? Color.white.opacity(0.045) : Color.clear)
        .overlay(alignment: .leading) {
            if session.cropping || session.selecting {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.cropping)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.selecting)
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
        } else if session.selecting, let image = session.displayedImage {
            GeometryReader { geo in
                let aspect = max(image.size.width / max(image.size.height, 1), 0.01)
                let fitted = fittedSize(aspect: aspect, maxWidth: geo.size.width - 40, maxHeight: geo.size.height - 52)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                    SelectionCanvas(strokes: $session.strokes, brush: session.brush, erasing: session.erasing)
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
                .padding(.horizontal, 20)
                .padding(.top, 36)
                .padding(.bottom, 16)
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
        .background(Color.white.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
        }
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

    private func iconButton(
        _ symbol: String,
        on: Bool = false,
        enabled: Bool = true,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.white.opacity(0.92) : Color.white.opacity(0.28))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(on ? 0.18 : 0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 14
            let cols = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                for col in 0..<cols {
                    let light = (row + col).isMultiple(of: 2)
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: light ? 0.22 : 0.14)))
                }
            }
        }
    }
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
