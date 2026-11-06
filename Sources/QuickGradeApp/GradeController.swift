import AppKit
@preconcurrency import QuickGradeCore
import SwiftUI

final class GradePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Staying a key panel, not the main window, leaves Finder's highlight in place.
    override var canBecomeMain: Bool { false }
}


final class GradeHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let windowPoint = superview?.convert(point, to: nil) ?? convert(point, from: superview)
        if let slider = Self.slider(in: self, windowPoint: windowPoint) {
            return slider
        }
        return super.hitTest(point)
    }

    private static func slider(in view: NSView, windowPoint: NSPoint) -> NSView? {
        for subview in view.subviews.reversed() {
            if let found = slider(in: subview, windowPoint: windowPoint) { return found }
        }
        guard view is SliderDragView else { return nil }
        let local = view.convert(windowPoint, from: nil)
        return view.bounds.insetBy(dx: -2, dy: -8).contains(local) ? view : nil
    }
}

enum SpaceAction: Sendable {
    case ignore
    /// Eat this Space press. Finder must not see it, or it arms Quick Look for the next file.
    case swallow
    case close
    case open([URL])
    case resolve([String])
}

@MainActor
final class GradeController: NSObject, NSWindowDelegate {
    static let shared = GradeController()

    let session = GradeSession()

    private var panel: GradePanel?
    private var urls: [URL] = []
    private var index = 0
    private var sourceURL: URL?
    private var sourcePreview: CGImage?
    /// Original long side / preview long side. Full-resolution saves stay at 1.
    private var previewGrainScale: CGFloat = 1
    private var filterThumbToken = 0
    private var filterThumbBase: GradeSettings?
    private var filterThumbCropping = false
    private let renderQueue = DispatchQueue(label: "quickgrade.render", qos: .userInteractive)
    private let filterThumbQueue = DispatchQueue(label: "quickgrade.filters", qos: .utility)
    private var rendering = false
    private var pending = false
    private var opening = false
    private var closing = false
    private var ignoreResignUntil = Date.distantPast
    private var reopenURL: URL?
    private var reopenUntil = Date.distantPast
    private var catalogToken = 0
    private var keyMonitor: Any?
    private var zoomMonitor: Any?
    private var gestureTap: CFMachPort?
    private var gestureSource: CFRunLoopSource?
    private var compareDownAt: Date?
    private var compareDown = false
    private var saveTask: Task<Void, Never>?
    private var iconTasks: [String: Task<Void, Never>] = [:]
    private var iconTokens: [String: Int] = [:]
    private let iconQueue = DispatchQueue(label: "quickgrade.icon", qos: .utility)
    private let iconRefreshQueue = DispatchQueue(label: "quickgrade.iconrefresh", qos: .utility)
    private var pendingIconPaths: Set<String> = []
    private var iconRefreshScheduled = false
    private var cutoutPreview: CGImage?
    private var displayedCG: CGImage?
    private var cutoutToken = 0
    private var lastComparable: GradeSettings?
    private var lastCropping = false
    private var lastCutoutCrop = CropEdit.identity
    private var lastCutoutCropping = false
    private var lastSelectionReach = 0.55
    private var lastSelectionStrokes: [SelectionStroke] = []

    private override init() {
        super.init()
        session.onChange = { [weak self] in
            self?.scheduleRender()
            self?.schedulePersist()
        }
        session.performGo = { [weak self] delta in self?.go(by: delta) }
        session.performSave = { [weak self] in self?.save() }
        session.performClose = { [weak self] in self?.close() }
        session.performCopyImage = { [weak self] in self?.copyImage() }
        session.performApplySelection = { [weak self] in self?.applySelection() }
    }

    func spaceAction() -> SpaceAction {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let mine = Bundle.main.bundleIdentifier
        if let panel, panel.isVisible, !closing {
            if panel.isKeyWindow || front == "com.apple.finder" || front == mine {
                return .close
            }
        }
        guard front == "com.apple.finder" || front == mine else { return .ignore }
        switch FinderSelection.current() {
        case .photos(let urls) where !urls.isEmpty:
            return .open(urls)
        case .names(let names):
            return .resolve(names)
        case .empty:
            guard front == "com.apple.finder" else { return .ignore }
            return .swallow
        case .other, .photos, .unknown:
            return .ignore
        }
    }

    func openFinderNames(_ names: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let folder = FinderSelection.frontWindowFolder() else { return }
            let urls = names.map { folder.appendingPathComponent($0) }
                .filter(ImageKind.opensInShelf)
            guard !urls.isEmpty else { return }
            DispatchQueue.main.async {
                SelectionCache.shared.noteFolder(folder)
                self?.open(urls: urls)
            }
        }
    }

    func open(urls selected: [URL], keepGrade: Bool = false) {
        dismissQuickLookSoon()
        let selected = selected.map(ImageKind.posixFileURL)
        let photos = selected.filter(ImageKind.isPhoto)
        guard let current = photos.last ?? selected.last else { return }
        catalogToken += 1
        if photos.count > 1 {
            urls = photos.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            index = urls.firstIndex(of: current) ?? 0
        } else {
            urls = [current]
            index = 0
            let token = catalogToken
            let folderURL = current
            renderQueue.async {
                let list = ImageLoading.images(inSameFolderAs: folderURL)
                DispatchQueue.main.async {
                    guard token == self.catalogToken, self.sourceURL == folderURL else { return }
                    self.urls = list
                    self.index = list.firstIndex(of: folderURL) ?? 0
                    self.syncChrome()
                }
            }
        }
        show(current, keepGrade: keepGrade)
    }

    func appResigned() {
        guard !opening, Date() > ignoreResignUntil else { return }
        close(restoreSelection: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !opening, !closing, Date() > ignoreResignUntil else { return }
        close(restoreSelection: false)
    }

    func close() {
        close(restoreSelection: true)
    }

    func close(restoreSelection: Bool) {
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        let url = sourceURL
        let settings = session.settings
        saveTask?.cancel()
        if let url {
            GradeStore.save(settings, for: url)
            scheduleIcon(url, settings)
        }
        panel.orderOut(nil)
        panel.alphaValue = 1
        releasePreview()
        closing = false
        guard restoreSelection, let url else { return }
        reopenURL = url
        reopenUntil = Date().addingTimeInterval(4)
        FinderSelection.reselectIfNeeded(url)
        guard NSApp.isActive,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        NSApp.yieldActivation(to: finder)
    }

    private func show(_ url: URL, keepGrade: Bool) {
        let url = ImageKind.posixFileURL(url)
        let pixels = GradeStore.originalURL(for: url)
        guard let preview = ImageLoading.oriented(url: pixels, maxPixel: 1800) else {
            session.flash("Couldn't read this photo")
            present(pixelSize: CGSize(width: 1600, height: 1000))
            return
        }
        if !keepGrade {
            session.settings = GradeStore.load(for: url) ?? .neutral
            session.undoManager.removeAllActions()
            session.refreshHistory()
        }
        session.originalLocked = false
        session.originalHeld = false
        session.lifting = false
        session.cropping = false
        session.cropFrame = session.settings.crop.rect
        session.selecting = false
        if !session.settings.isNeutral {
            refreshFinderIcon(url)
        }
        session.applyingSelection = false
        session.strokes = session.settings.selectionStrokes
        session.sourceAspect = CGFloat(preview.width) / CGFloat(max(preview.height, 1))
        displayedCG = preview
        lastComparable = nil
        lastCutoutCrop = .identity
        lastCutoutCropping = false
        lastSelectionReach = session.settings.selectionReach
        lastSelectionStrokes = session.settings.selectionStrokes
        session.hideHUD()
        cutoutPreview = nil
        cutoutToken += 1
        sourceURL = url
        sourcePreview = preview
        previewGrainScale = ImageLoading.grainScale(of: preview, againstOriginal: pixels)
        session.filterThumbnails = [:]
        filterThumbBase = nil
        session.fileName = url.lastPathComponent
        let image = nsImage(preview)
        session.originalImage = image
        session.gradedImage = image
        let histogram = Histogram.compute(preview)
        session.originalHistogram = histogram
        session.histogram = histogram
        syncChrome()
        present(pixelSize: CGSize(width: preview.width, height: preview.height))
        scheduleRender()
        scheduleIcon(url, session.settings, delay: 600_000_000)
    }

    private func present(pixelSize: CGSize) {
        let panel = ensurePanel()
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let frame = frame(for: pixelSize)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        opening = true
        ignoreResignUntil = Date().addingTimeInterval(0.8)
        let start = reduce ? frame : frame.insetBy(dx: 8, dy: 8)
        panel.setFrame(start, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        if reduce {
            panel.setFrame(frame, display: true)
            opening = false
            panel.invalidateShadow()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.opening = false
                    panel.alphaValue = 1
                    panel.invalidateShadow()
                }
            }
        }
    }

    private func ensurePanel() -> GradePanel {
        if let panel {
            installZoom()
            return panel
        }
        let panel = GradePanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.minSize = NSSize(width: 1040, height: 680)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let host = GradeHost(rootView: GradeOverlay(session: session))
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        panel.contentView = host
        self.panel = panel
        installKeys()
        installZoom()
        return panel
    }

    private func frame(for pixelSize: CGSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let side: CGFloat = 348
        let maxW = min(visible.width * 0.94, 1680)
        let maxH = visible.height * 0.9
        let aspect = max(pixelSize.width, 1) / max(pixelSize.height, 1)
        let maxImageW = max(maxW - side, 560)
        var imageH = maxH
        var imageW = imageH * aspect
        if imageW > maxImageW {
            imageW = maxImageW
            imageH = imageW / aspect
        }
        let width = min(max(imageW + side, 1040), maxW)
        let height = min(max(imageH, 680), maxH)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private func scheduleRender() {
        guard let source = sourcePreview else { return }
        var cutoutComparable = session.settings.crop
        if session.cropping {
            cutoutComparable.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if cutoutComparable != lastCutoutCrop || session.cropping != lastCutoutCropping {
            cutoutPreview = nil
            lastCutoutCrop = cutoutComparable
            lastCutoutCropping = session.cropping
        }
        if session.settings.selectionReach != lastSelectionReach
            || session.settings.selectionStrokes != lastSelectionStrokes {
            cutoutPreview = nil
            lastSelectionReach = session.settings.selectionReach
            lastSelectionStrokes = session.settings.selectionStrokes
        }
        let wantMask = session.settings.removeBackground
        if wantMask && cutoutPreview == nil && !session.applyingSelection {
            if session.settings.selectionStrokes.isEmpty {
                scheduleCutout()
            } else {
                scheduleStrokeCutout()
            }
        }
        var comparable = session.settings
        if session.cropping {
            comparable.crop.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if session.cropping, !session.settings.removeBackground, lastCropping, lastComparable == comparable, session.gradedImage != nil {
            scheduleFilterThumbnails(source: source)
            return
        }
        lastComparable = comparable
        lastCropping = session.cropping
        let mask = wantMask ? cutoutPreview : nil
        if session.settings.isNeutral && !session.showClipping && mask == nil {
            displayedCG = source
            session.gradedImage = session.originalImage
            session.histogram = session.originalHistogram
            pending = false
            scheduleFilterThumbnails(source: source)
            return
        }
        if wantMask && mask == nil {
            return
        }
        if rendering {
            pending = true
            return
        }
        rendering = true
        let settings = session.settings
        let clipping = session.showClipping
        let cropping = session.cropping
        let grainScale = previewGrainScale
        renderQueue.async { [weak self] in
            let graded = GradeEngine.render(source: source, settings: settings, showClipping: clipping, cropRect: !cropping, grainScale: grainScale)
            let histogram = Histogram.compute(graded)
            let output = mask.map { GradeEngine.applyingMask(from: $0, to: graded) } ?? graded
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                guard self.sourcePreview === source else {
                    if self.pending {
                        self.pending = false
                        self.scheduleRender()
                    }
                    return
                }
                self.displayedCG = output
                self.session.gradedImage = self.nsImage(output)
                self.session.histogram = histogram
                self.scheduleFilterThumbnails(source: source)
                if self.pending {
                    self.pending = false
                    self.scheduleRender()
                }
            }
        }
    }

    private func save() {
        guard let sourceURL, !session.isSaving else { return }
        guard session.isDirty else {
            session.flash("Nothing to save")
            return
        }
        session.isSaving = true
        let settings = session.settings
        renderQueue.async { [weak self] in
            let pixels = GradeStore.originalURL(for: sourceURL)
            guard let full = ImageLoading.oriented(url: pixels, maxPixel: nil) else {
                DispatchQueue.main.async {
                    self?.session.isSaving = false
                    self?.session.flash("Couldn't read the original")
                }
                return
            }
            var graded = GradeEngine.render(source: full, settings: settings, showClipping: false)
            if settings.removeBackground {
                do {
                    if settings.selectionStrokes.isEmpty {
                        let prepared = GradeEngine.applyingGeometry(to: full, edit: settings.crop, cropRect: true)
                        let cut = try SubjectCutout.cutout(source: prepared)
                        graded = GradeEngine.applyingMask(from: cut, to: graded)
                    } else {
                        graded = try SelectionMask.cutout(
                            source: graded,
                            strokes: settings.selectionStrokes,
                            reach: CGFloat(settings.selectionReach)
                        )
                    }
                } catch {
                    DispatchQueue.main.async { self?.session.flash("Saved without a cutout") }
                }
            }
            let transparent = ImageTransfer.hasTransparency(graded)
            let ext = ImageTransfer.exportExtension(sourceExtension: sourceURL.pathExtension, transparent: transparent)
            let destination = ImageLoading.destinationURL(for: sourceURL, preferredExtension: ext)
            do {
                try ImageLoading.write(graded, to: destination, copyingMetadataFrom: pixels)
                DispatchQueue.main.async {
                    self?.finishSave(name: destination.lastPathComponent)
                }
            } catch {
                if transparent {
                    DispatchQueue.main.async {
                        self?.session.isSaving = false
                        self?.session.flash("Couldn't save the copy")
                    }
                } else {
                    let jpeg = destination.deletingPathExtension().appendingPathExtension("jpg")
                    do {
                        try ImageLoading.write(graded, to: jpeg, copyingMetadataFrom: pixels)
                        DispatchQueue.main.async { self?.finishSave(name: jpeg.lastPathComponent) }
                    } catch {
                        DispatchQueue.main.async {
                            self?.session.isSaving = false
                            self?.session.flash("Couldn't save the copy")
                        }
                    }
                }
            }
        }
    }

    private func finishSave(name: String) {
        session.isSaving = false
        session.didJustSave = true
        session.flash("Saved \(name)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            self.session.didJustSave = false
        }
    }

    private func copyImage() {
        let cg = session.showingOriginal ? sourcePreview : (displayedCG ?? sourcePreview)
        guard let cg, let data = ImageTransfer.pngData(cg) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        session.flash("Image copied")
    }

    func historyKey(redo: Bool) -> Bool {
        guard let panel, panel.isVisible, !closing else { return false }
        if redo { session.redo() } else { session.undo() }
        return true
    }

    private func applySelection() {
        guard let source = sourcePreview else {
            session.finishSelection(maskReady: false)
            return
        }
        cutoutPreview = nil
        let strokes = session.strokes
        let settings = session.settings
        let reach = CGFloat(settings.selectionReach)
        let grainScale = previewGrainScale
        renderQueue.async { [weak self] in
            let graded = GradeEngine.render(source: source, settings: settings, showClipping: false, cropRect: true, grainScale: grainScale)
            let cut: CGImage?
            do {
                cut = try SelectionMask.cutout(source: graded, strokes: strokes, reach: reach)
            } catch {
                cut = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let cut else {
                    self.session.finishSelection(maskReady: false)
                    return
                }
                self.cutoutPreview = cut
                self.lastSelectionReach = self.session.settings.selectionReach
                self.lastSelectionStrokes = self.session.strokes
                self.session.finishSelection(maskReady: true)
                self.scheduleRender()
            }
        }
    }

    private func scheduleStrokeCutout() {
        guard cutoutPreview == nil, !session.lifting, let source = sourcePreview else { return }
        let strokes = session.settings.selectionStrokes
        guard !strokes.isEmpty else { return }
        session.lifting = true
        cutoutToken += 1
        let token = cutoutToken
        let settings = session.settings
        let grainScale = previewGrainScale
        renderQueue.async { [weak self] in
            let graded = GradeEngine.render(source: source, settings: settings, showClipping: false, cropRect: true, grainScale: grainScale)
            let image: CGImage?
            do {
                image = try SelectionMask.cutout(
                    source: graded,
                    strokes: strokes,
                    reach: CGFloat(settings.selectionReach)
                )
            } catch {
                image = nil
            }
            DispatchQueue.main.async {
                guard let self, self.cutoutToken == token else { return }
                self.session.lifting = false
                guard self.sourcePreview === source, self.session.settings.removeBackground else { return }
                guard let image else {
                    self.session.backgroundUnavailable()
                    return
                }
                self.cutoutPreview = image
                self.scheduleRender()
            }
        }
    }

    private func go(by delta: Int) {
        let next = index + delta
        guard urls.indices.contains(next) else { return }
        saveTask?.cancel()
        if let sourceURL {
            let leaving = session.settings
            GradeStore.save(leaving, for: sourceURL)
            scheduleIcon(sourceURL, leaving)
        }
        index = next
        show(urls[index], keepGrade: false)
    }

    private func schedulePersist() {
        guard let url = sourceURL else { return }
        let settings = session.settings
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            GradeStore.save(settings, for: url)
            scheduleIcon(url, settings)
        }
    }

    /// Finder icon view draws the file itself. The untouched original is copied
    /// into Application Support first, then the graded pixels replace the file
    /// so the thumbnail matches. Revert puts the original bytes back.
    private func scheduleIcon(_ url: URL, _ settings: GradeSettings, delay: UInt64 = 0) {
        let url = ImageKind.posixFileURL(url)
        let key = url.path
        iconTasks[key]?.cancel()
        let token = (iconTokens[key] ?? 0) + 1
        iconTokens[key] = token
        iconTasks[key] = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, self.iconTokens[key] == token else { return }
            }
            self.writeIcon(url, settings: settings, token: token)
        }
    }

    private func writeIcon(_ url: URL, settings: GradeSettings, token: Int) {
        let url = ImageKind.posixFileURL(url)
        let key = url.path
        guard iconTokens[key] == token else { return }
        if GradeStore.iconIsCurrent(settings, for: url) { return }
        if settings.isNeutral {
            GradeStore.restoreOriginal(of: url)
            refreshFinderIcon(url)
            repairSelection(url)
            return
        }
        guard let ext = ImageKind.shelfWriteExtension(url.pathExtension) else { return }
        guard GradeStore.preserveOriginal(of: url) else { return }
        let pixels = GradeStore.originalURL(for: url)
        iconQueue.async { [weak self] in
            guard let graded = self?.renderGraded(from: pixels, settings: settings) else { return }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("quickgrade-icon-" + UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try ImageLoading.write(graded, to: temp, copyingMetadataFrom: pixels)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            DispatchQueue.main.async {
                guard let self, self.iconTokens[url.path] == token else {
                    try? FileManager.default.removeItem(at: temp)
                    return
                }
                do {
                    try GradeStore.swapIn(temp, replacing: url)
                    guard FileManager.default.fileExists(atPath: url.path),
                          ImageKind.opensInShelf(url) else {
                        return
                    }
                    GradeStore.markIcon(settings, for: url)
                    self.refreshFinderIcon(url)
                    self.repairSelection(url)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                }
            }
        }
    }

    private func renderGraded(from pixels: URL, settings: GradeSettings) -> CGImage? {
        guard let full = ImageLoading.oriented(url: pixels, maxPixel: nil) else { return nil }
        var graded = GradeEngine.render(source: full, settings: settings, showClipping: false)
        guard settings.removeBackground else { return graded }
        do {
            if settings.selectionStrokes.isEmpty {
                let prepared = GradeEngine.applyingGeometry(to: full, edit: settings.crop, cropRect: true)
                let cut = try SubjectCutout.cutout(source: prepared)
                graded = GradeEngine.applyingMask(from: cut, to: graded)
            } else {
                graded = try SelectionMask.cutout(
                    source: graded,
                    strokes: settings.selectionStrokes,
                    reach: CGFloat(settings.selectionReach)
                )
            }
        } catch {
            return graded
        }
        return graded
    }

    /// After the shelf closes, point Finder at the same path again.
    /// The thumbnail replace uses a new inode, and the old selection URL would not resolve.
    private func repairSelection(_ url: URL) {
        guard panel?.isVisible != true, FileManager.default.fileExists(atPath: url.path) else { return }
        FinderSelection.reselectIfUnresolved(url)
    }

    private func refreshFinderIcon(_ url: URL) {
        var file = url
        var values = URLResourceValues()
        values.contentModificationDate = Date()
        try? file.setResourceValues(values)
        NSWorkspace.shared.noteFileSystemChanged(url.path)
        NSWorkspace.shared.noteFileSystemChanged(url.deletingLastPathComponent().path)
        let path = url.path
        iconRefreshQueue.async { [weak self] in
            guard let self else { return }
            self.pendingIconPaths.insert(path)
            guard !self.iconRefreshScheduled else { return }
            self.iconRefreshScheduled = true
            self.iconRefreshQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let paths = Array(self.pendingIconPaths)
                self.pendingIconPaths.removeAll()
                self.iconRefreshScheduled = false
                self.flushFinderIcons(paths)
            }
        }
    }

    /// Finder icon view keeps the previous thumbnail until Quick Look drops its
    /// cache and the open folder redraws. The file itself stays at the same path.
    private func flushFinderIcons(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        reset.arguments = ["-r"]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        try? reset.run()
        reset.waitUntilExit()
        let tell = Process()
        tell.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        tell.arguments = [
            "-e",
            """
            on run argv
                tell application "Finder"
                    repeat with p in argv
                        try
                            set f to (POSIX file (p as text)) as alias
                            update f
                            update container of f
                        end try
                    end repeat
                end tell
            end run
            """
        ] + paths
        tell.standardOutput = FileHandle.nullDevice
        tell.standardError = FileHandle.nullDevice
        try? tell.run()
        tell.waitUntilExit()
    }

    private func syncChrome() {
        if urls.count > 1 {
            session.positionText = "\(index + 1) / \(urls.count)"
            session.canGoBack = index > 0
            session.canGoForward = index < urls.count - 1
        } else {
            session.positionText = nil
            session.canGoBack = false
            session.canGoForward = false
        }
        session.canPaste = GradeClipboard.settings != nil
    }

    /// Pinch is not delivered to a background panel, and a global NSEvent monitor
    /// never sees it. A gesture tap does, including while Finder stays in front.
    private func installZoom() {
        guard zoomMonitor == nil else { return }
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { event in
            let handled = MainActor.assumeIsolated { GradeController.shared.zoomEvent(event) }
            return handled ? nil : event
        }
        installGestureTap()
    }

    private func installGestureTap() {
        guard gestureTap == nil else { return }
        let mask = CGEventMask((1 << 29) | (1 << 30) | (1 << CGEventType.scrollWheel.rawValue))
        let user = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, user in
            guard let user else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<GradeController>.fromOpaque(user).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.gestureTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let handled: Bool
            if Thread.isMainThread {
                handled = MainActor.assumeIsolated { controller.consumeGesture(event) }
            } else {
                handled = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { controller.consumeGesture(event) }
                }
            }
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        gestureTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: user
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: user
        )
        guard let gestureTap else { return }
        gestureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gestureTap, 0)
        if let gestureSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), gestureSource, .commonModes)
        }
        CGEvent.tapEnable(tap: gestureTap, enable: true)
    }

    private func consumeGesture(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event) else { return false }
        return zoomEvent(ns)
    }

    private func zoomEvent(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible, !session.selecting else { return false }
        guard session.displayedImage != nil else { return false }
        let mouse = NSEvent.mouseLocation
        var stage = panel.frame
        stage.size.width = max(stage.width - 340, 1)
        guard stage.contains(mouse) else { return false }
        let magnify = event.type == .magnify || event.type == .gesture || event.type.rawValue == 29 || event.type.rawValue == 30
        if magnify {
            guard abs(event.magnification) > 0.00001 else { return true }
            applyPinch(event.magnification, mouse: mouse, stage: stage)
            return true
        }
        guard event.type == .scrollWheel else { return false }
        let ours = event.window == nil || event.window === panel
        guard ours, session.zoom > 1.01 else { return false }
        var moved = session.pan
        moved.width += event.scrollingDeltaX
        moved.height += event.scrollingDeltaY
        session.pan = clampPan(moved, zoom: session.zoom, stage: panLimit(stage: stage))
        if session.cropping { session.applyViewedCrop() }
        return true
    }

    private func applyPinch(_ magnification: CGFloat, mouse: CGPoint, stage: CGRect) {
        let old = session.zoom
        let next = min(8, max(1, old * (1 + magnification)))
        if next <= 1.01 {
            session.zoom = 1
            session.pan = .zero
            if session.cropping { session.applyViewedCrop() }
            return
        }
        let cursor = CGPoint(x: mouse.x - stage.minX, y: stage.maxY - mouse.y)
        let center = CGPoint(x: stage.width / 2, y: stage.height / 2)
        let ratio = next / max(old, 0.01)
        let pan0 = session.pan
        let anchored = CGSize(
            width: pan0.width * ratio + (cursor.x - center.x) * (1 - ratio),
            height: pan0.height * ratio + (cursor.y - center.y) * (1 - ratio)
        )
        session.zoom = next
        session.pan = clampPan(anchored, zoom: next, stage: panLimit(stage: stage))
        if session.cropping { session.applyViewedCrop() }
    }

    private func panLimit(stage: CGRect) -> CGSize {
        if session.cropping, session.cropViewSize.width > 2, session.cropViewSize.height > 2 {
            return session.cropViewSize
        }
        return stage.size
    }

    private func clampPan(_ pan: CGSize, zoom: CGFloat, stage: CGSize) -> CGSize {
        let maxX = stage.width * (zoom - 1) * 0.5
        let maxY = stage.height * (zoom - 1) * 0.5
        return CGSize(
            width: min(max(pan.width, -maxX), maxX),
            height: min(max(pan.height, -maxY), maxY)
        )
    }

    /// If a slow key let Quick Look open on a photo, close that panel once the shelf is up.
    private func dismissQuickLookSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.dismissQuickLook()
        }
    }

    private func dismissQuickLook() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var pids = Set<pid_t>()
        for window in info {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            if owner.localizedCaseInsensitiveContains("Quick Look") || owner.localizedCaseInsensitiveContains("QuickLook") {
                if let pid = window[kCGWindowOwnerPID as String] as? NSNumber {
                    pids.insert(pid_t(pid.int32Value))
                }
            }
        }
        guard !pids.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for pid in pids {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
            down?.postToPid(pid)
            up?.postToPid(pid)
        }
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let plain = flags.subtracting([.capsLock, .numericPad, .function]).isEmpty

        if event.type == .keyUp, event.keyCode == 42 {
            session.setCompareHeld(false)
            if let start = compareDownAt, Date().timeIntervalSince(start) < 0.18 {
                session.toggleCompareLock()
            }
            compareDown = false
            compareDownAt = nil
            return true
        }
        guard event.type == .keyDown, !event.isARepeat else { return false }

        if event.keyCode == 42, plain {
            if !compareDown {
                compareDown = true
                compareDownAt = Date()
                session.setCompareHeld(true)
            }
            return true
        }
        if event.keyCode == 49 || event.keyCode == 53 {
            close()
            return true
        }
        if command && event.keyCode == 1 {
            save()
            return true
        }
        if command && shift && event.keyCode == 6 {
            session.redo()
            return true
        }
        if command && event.keyCode == 6 {
            session.undo()
            return true
        }
        if command && shift && event.keyCode == 8 {
            session.copyAdjustments()
            return true
        }
        if command && shift && event.keyCode == 9 {
            session.pasteAdjustments()
            return true
        }
        if command && event.keyCode == 8 {
            copyImage()
            return true
        }
        if plain && event.keyCode == 38 {
            session.toggleClipping()
            return true
        }
        if plain && (event.keyCode == 123 || event.keyCode == 124) {
            go(by: event.keyCode == 123 ? -1 : 1)
            return true
        }
        if plain, let page = page(for: event.keyCode) {
            session.page = page
            return true
        }
        return false
    }

    private func page(for keyCode: UInt16) -> GradePage? {
        switch keyCode {
        case 18: return .light
        case 19: return .whiteBalance
        case 20: return .hsl
        case 21: return .style
        case 23: return .curves
        case 22: return .filters
        default: return nil
        }
    }

    private func scheduleCutout() {
        guard cutoutPreview == nil, !session.lifting, let source = sourcePreview else { return }
        session.lifting = true
        cutoutToken += 1
        let token = cutoutToken
        let edit = session.settings.crop
        let cropRect = !session.cropping
        renderQueue.async { [weak self] in
            let image: CGImage?
            do {
                let prepared = GradeEngine.applyingGeometry(
                    to: source,
                    edit: edit,
                    cropRect: cropRect
                )
                image = try SubjectCutout.cutout(source: prepared)
            } catch {
                image = nil
            }
            DispatchQueue.main.async {
                guard let self, self.cutoutToken == token else { return }
                self.session.lifting = false
                guard self.sourcePreview === source, self.session.settings.removeBackground else { return }
                guard let image else {
                    self.session.backgroundUnavailable()
                    return
                }
                self.cutoutPreview = image
                self.scheduleRender()
            }
        }
    }

    private func releasePreview() {
        sourcePreview = nil
        previewGrainScale = 1
        sourceURL = nil
        filterThumbBase = nil
        session.filterThumbnails = [:]
        cutoutPreview = nil
        cutoutToken += 1
        session.lifting = false
        session.gradedImage = nil
        session.originalImage = nil
    }

    private func scheduleFilterThumbnails(source: CGImage) {
        var bare = session.settings
        bare.filter = .original
        bare.filterStrength = 100
        let cropping = session.cropping
        if cropping {
            bare.crop.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if filterThumbBase == bare,
           filterThumbCropping == cropping,
           session.filterThumbnails.count == PhotoFilter.allCases.count {
            return
        }
        filterThumbToken += 1
        let token = filterThumbToken
        let pixels = sourceURL.map { GradeStore.originalURL(for: $0) }
        let captured = source
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard self.filterThumbToken == token else { return }
            self.filterThumbQueue.async { [weak self] in
                let small = Self.downscaled(captured, longSide: 180)
                let scale = pixels.map { ImageLoading.grainScale(of: small, againstOriginal: $0) } ?? 1
                var rendered: [PhotoFilter: CGImage] = [:]
                for filter in PhotoFilter.allCases {
                    var settings = bare
                    settings.filter = filter
                    settings.filterStrength = 100
                    rendered[filter] = GradeEngine.render(
                        source: small,
                        settings: settings,
                        showClipping: false,
                        cropRect: !cropping,
                        grainScale: scale
                    )
                }
                DispatchQueue.main.async {
                    guard let self, self.filterThumbToken == token else { return }
                    var thumbs: [PhotoFilter: NSImage] = [:]
                    for (filter, image) in rendered {
                        thumbs[filter] = self.nsImage(image)
                    }
                    self.filterThumbBase = bare
                    self.filterThumbCropping = cropping
                    self.session.filterThumbnails = thumbs
                }
            }
        }
    }

    private static func downscaled(_ image: CGImage, longSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longSide else { return image }
        let scale = CGFloat(longSide) / CGFloat(longest)
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func nsImage(_ image: CGImage) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return NSImage(cgImage: image, size: size)
    }
}
