import AppKit
import QuickGradeCore
import SwiftUI

struct ControlHUD: Equatable {
    var symbol: String
    var name: String
    var value: String
}

enum GradeClipboard {
    static var settings: GradeSettings?
}

@MainActor
@Observable
final class GradeSession {
    var settings = GradeSettings.neutral
    var page: GradePage = .light
    var selectedBand: HSLBand = .red
    var curveChannel: CurveChannel = .rgb
    var originalLocked = false
    var originalHeld = false
    var showClipping = false
    var lifting = false
    var cropping = false
    var selecting = false
    var brush: CGFloat = 28
    var erasing = false
    var strokes: [SelectionStroke] = []
    var applyingSelection = false
    var performApplySelection: () -> Void = {}
    var sourceAspect: CGFloat = 1
    var cropInteracting = false {
        didSet {
            if cropInteracting {
                beginEdit(action: "Crop")
            } else {
                endEdit()
            }
        }
    }
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// Crop rectangle as drawn, in the fitted image view. Pinch and pan move the photo under it.
    var cropFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cropViewSize = CGSize(width: 1, height: 1)
    var fileName = ""
    var positionText: String?
    var canGoBack = false
    var canGoForward = false
    var canUndo = false
    var canRedo = false
    var isSaving = false
    var didJustSave = false
    var notice: String?
    var hud: ControlHUD?
    var isAdjusting = false
    var canPaste = false
    var gradedImage: NSImage?
    var originalImage: NSImage?
    var filterThumbnails: [PhotoFilter: NSImage] = [:]
    var histogram = Histogram.empty()
    var originalHistogram = Histogram.empty()

    var showingOriginal: Bool { originalLocked != originalHeld }
    var isDirty: Bool { settings != .neutral }
    var displayedImage: NSImage? { showingOriginal ? originalImage : gradedImage }
    var displayedHistogram: Histogram { showingOriginal ? originalHistogram : histogram }

    let undoManager = UndoManager()
    var onChange: (() -> Void)?
    var performGo: (Int) -> Void = { _ in }
    var performSave: () -> Void = {}
    var performClose: () -> Void = {}
    var performCopyImage: () -> Void = {}

    private var editBaseline: GradeSettings?
    private var editAction: String?
    private var cropGestureEnd: Task<Void, Never>?

    func value(for keyPath: WritableKeyPath<GradeSettings, Double>) -> Double {
        settings[keyPath: keyPath]
    }

    func beginEdit(action: String) {
        if editBaseline == nil {
            editBaseline = settings
            editAction = action
            isAdjusting = true
        }
    }

    func set(_ keyPath: WritableKeyPath<GradeSettings, Double>, to value: Double) {
        settings[keyPath: keyPath] = value
        onChange?()
    }

    func selectFilter(_ filter: PhotoFilter) {
        endEdit()
        let before = settings
        if filter == .original {
            settings.filter = .original
            settings.filterStrength = 100
        } else if settings.filter != filter {
            if settings.filter == .original {
                settings.filterStrength = 100
            }
            settings.filter = filter
        }
        commit(from: before, action: filter.title)
    }

    func beginFilterStrengthEdit() {
        beginEdit(action: "\(settings.filter.title) Strength")
    }

    func setFilterStrength(_ value: Double) {
        let next = min(max(value, 0), 100)
        settings.filterStrength = next
        showHUD(symbol: "camera.filters", name: settings.filter.title, value: String(format: "%.0f", next))
        onChange?()
    }

    func endEdit() {
        finishEdit()
    }

    func beginHSLEdit() {
        beginEdit(action: "HSL")
    }

    func setHSL(_ keyPath: WritableKeyPath<HSLAdjustment, Double>, to value: Double) {
        var adjustment = settings.adjustment(for: selectedBand)
        adjustment[keyPath: keyPath] = value
        settings.setAdjustment(adjustment, for: selectedBand)
        onChange?()
    }

    func hslValue(_ keyPath: WritableKeyPath<HSLAdjustment, Double>) -> Double {
        settings.adjustment(for: selectedBand)[keyPath: keyPath]
    }

    func beginCurveEdit() {
        beginEdit(action: "Curves")
    }

    func setCurve(_ points: [CurvePoint]) {
        settings.curves[curveChannel] = ToneCurve(points: points)
        onChange?()
    }

    func resetPage() {
        let before = settings
        guard !settings.isPageNeutral(page) else { return }
        withAnimation(.snappy(duration: 0.28)) {
            settings.reset(page)
        }
        commit(from: before, action: "Reset \(page.title)")
    }

    func resetAll() {
        let before = settings
        guard before != .neutral else { return }
        withAnimation(.snappy(duration: 0.28)) {
            settings = .neutral
        }
        commit(from: before, action: "Reset All")
    }

    func setCompareHeld(_ held: Bool) {
        originalHeld = held
    }

    func toggleCompareLock() {
        originalLocked.toggle()
    }

    func toggleClipping() {
        showClipping.toggle()
        onChange?()
    }

    func toggleCrop() {
        if cropInteracting { cropInteracting = false }
        if selecting { selecting = false }
        cropping.toggle()
        if cropping {
            cropFrame = settings.crop.rect
            zoom = 1
            pan = .zero
        }
        onChange?()
    }

    func rememberCropView(_ size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        cropViewSize = size
    }

    /// Writes the image region currently inside the on-screen crop frame.
    func applyViewedCrop() {
        guard cropping, cropViewSize.width > 2, cropViewSize.height > 2 else { return }
        let rect = CropGeometry.imageRect(
            covering: cropFrame,
            zoom: zoom,
            pan: pan,
            viewSize: cropViewSize
        )
        let next = settings.crop.replacing(rect: rect)
        guard next != settings.crop else { return }
        if editBaseline == nil { beginEdit(action: "Crop") }
        settings.crop = next
        onChange?()
        cropGestureEnd?.cancel()
        cropGestureEnd = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, !self.cropInteracting else { return }
            self.endEdit()
        }
    }

    func toggleSelection() {
        if cropInteracting { cropInteracting = false }
        if cropping { cropping = false }
        selecting.toggle()
        if selecting {
            strokes = settings.selectionStrokes
        }
        onChange?()
    }

    func applySelection() {
        guard !strokes.isEmpty, !applyingSelection else { return }
        applyingSelection = true
        performApplySelection()
    }

    func finishSelection(maskReady: Bool) {
        applyingSelection = false
        guard maskReady else {
            flash("Couldn't keep that selection")
            return
        }
        let before = settings
        settings.selectionStrokes = strokes
        settings.removeBackground = true
        commit(from: before, action: "Remove Background")
    }

    func beginReach() {
        beginEdit(action: "Reach")
    }

    func previewReach(_ value: Double) {
        if editBaseline == nil { beginEdit(action: "Reach") }
        settings.selectionReach = min(max(value, 0), 1)
    }

    func endReach() {
        let before = editBaseline
        if settings.removeBackground, !strokes.isEmpty {
            settings.selectionStrokes = strokes
        }
        let changed = before.map { $0 != settings } ?? false
        let recut = changed && settings.removeBackground && !strokes.isEmpty
        if recut { applyingSelection = true }
        endEdit()
        if recut { performApplySelection() }
    }

    func undo() {
        undoManager.undo()
        refreshHistory()
    }

    func redo() {
        undoManager.redo()
        refreshHistory()
    }

    func refreshHistory() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    func restoreBackground() {
        let before = settings
        settings.removeBackground = false
        settings.selectionStrokes = []
        strokes = []
        selecting = false
        commit(from: before, action: "Restore Background")
    }

    func setCrop(_ edit: CropEdit) {
        if cropInteracting {
            if editBaseline == nil { beginEdit(action: "Crop") }
            settings.crop = edit
            onChange?()
        } else {
            let before = settings
            settings.crop = edit
            commit(from: before, action: "Crop")
        }
    }

    func backgroundUnavailable() {
        lifting = false
        guard settings.removeBackground else { return }
        let before = settings
        settings.removeBackground = false
        commit(from: before, action: "Remove Background")
        flash("Nothing to lift in this photo")
    }

    func showHUD(symbol: String, name: String, value: String) {
        let next = ControlHUD(symbol: symbol, name: name, value: value)
        if hud != next { hud = next }
    }

    func hideHUD() {
        hud = nil
    }

    func copyAdjustments() {
        GradeClipboard.settings = settings
        canPaste = true
        flash("Adjustments copied")
    }

    func pasteAdjustments() {
        guard let copied = GradeClipboard.settings else { return }
        let before = settings
        settings = copied
        commit(from: before, action: "Paste Adjustments")
    }

    func copyImage() {
        performCopyImage()
    }

    func go(by delta: Int) {
        guard !isAdjusting else { return }
        performGo(delta)
    }

    func save() {
        performSave()
    }

    func close() {
        performClose()
    }

    func prepareForNewPhoto() {
        originalLocked = false
        originalHeld = false
        hud = nil
        notice = nil
        didJustSave = false
        undoManager.removeAllActions()
        editBaseline = nil
        isAdjusting = false
        refreshHistory()
    }

    fileprivate func commit(from before: GradeSettings, action: String) {
        onChange?()
        guard before != settings else { return }
        let current = settings
        undoManager.registerUndo(withTarget: self) { me in
            me.replace(with: before, action: action, current: current)
        }
        undoManager.setActionName(action)
        refreshHistory()
    }

    private func finishEdit() {
        let before = editBaseline
        let action = editAction ?? "Adjust"
        editBaseline = nil
        editAction = nil
        isAdjusting = false
        hideHUD()
        guard let before, before != settings else { return }
        commit(from: before, action: action)
    }

    private func replace(with restored: GradeSettings, action: String, current: GradeSettings) {
        settings = restored
        onChange?()
        undoManager.registerUndo(withTarget: self) { me in
            me.replace(with: current, action: action, current: restored)
        }
        undoManager.setActionName(action)
        refreshHistory()
    }

    func flash(_ text: String) {
        notice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.notice == text { self.notice = nil }
        }
    }
}
