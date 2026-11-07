import AppKit
import ApplicationServices
import QuickGradeCore

enum FinderSelection {
    enum Read {
        case photos([URL])
        case names([String])
        case other
        /// A Finder file window is focused and no file is selected.
        case empty
        case unknown
    }

    /// Live Finder selection. The Space key handler calls this, so it stays on the
    /// focused item and a recent cache. A deep Finder walk here is slow enough
    /// that macOS gives the key to Quick Look before we can take it.
    static func current() -> Read {
        let hit = focusedSelection()
        let read = decision(urls: hit.urls, names: hit.names, folder: hit.folder)
        if case .empty = read {
            // Not a file window (Get Info, settings). Let Space through.
            guard hit.browser else { return .unknown }
            // Nothing is selected. A same-folder cache can still be a file the
            // shallow walk missed. recent(matching:) ignores other folders.
            if let cached = SelectionCache.shared.recent(matching: hit.folder) {
                return cached
            }
            SelectionCache.shared.refreshIfFinderIsFront()
            SelectionCache.shared.waitUntilSettled(timeout: 0.08)
            if let cached = SelectionCache.shared.recent(matching: hit.folder) {
                return cached
            }
            return .empty
        }
        if case .unknown = read {
            if let cached = SelectionCache.shared.recent(matching: hit.folder) {
                return cached
            }
            SelectionCache.shared.refreshIfFinderIsFront()
            SelectionCache.shared.waitUntilSettled(timeout: 0.08)
            if let cached = SelectionCache.shared.recent(matching: hit.folder) {
                return cached
            }
            return .unknown
        }
        return read
    }

    /// Focused row only. Icon view and list view both hang the selection off this element.
    private static func focusedSelection() -> (urls: [URL], names: [String], folder: URL?, browser: Bool) {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return ([], [], nil, false)
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        guard let window: AXUIElement = copy(app, kAXFocusedWindowAttribute as CFString), isFileBrowser(window) else {
            return ([], [], nil, false)
        }
        let folder = folderURL(of: window)
        guard let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute as CFString) else {
            return ([], [], folder, true)
        }
        let walked = climbing(from: focused, folder: folder)
        return (walked.urls, walked.names, folder, true)
    }

    fileprivate static func decision(urls: [URL], names: [String], folder: URL?) -> Read {
        if !urls.isEmpty { return classify(urls) }
        guard !names.isEmpty else { return .empty }
        if let folder {
            let resolved = names.compactMap { namedFile($0, in: folder) }
            if resolved.count == names.count { return classify(resolved) }
        }
        let shelf = names.compactMap(ImageKind.shelfSelectionName)
        if shelf.count == names.count { return .names(shelf) }
        if names.allSatisfy(isClearlyNotShelf) {
            SelectionCache.shared.note([])
            return .other
        }
        return .unknown
    }

    /// Finder icon view often exposes the display name with the extension hidden.
    private static func resolveName(_ name: String, in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard (name as NSString).pathExtension.isEmpty else { return nil }
        return listing(of: folder).first { $0.deletingPathExtension().lastPathComponent == name }
    }

    private static let listingLock = NSLock()
    private static var listingFolder = ""
    private static var listingFiles: [URL] = []
    private static var listingAt = Date.distantPast

    private static func listing(of folder: URL) -> [URL] {
        listingLock.lock()
        defer { listingLock.unlock() }
        if folder.path == listingFolder, Date().timeIntervalSince(listingAt) < 2 {
            return listingFiles
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        listingFolder = folder.path
        listingFiles = files
        listingAt = Date()
        return files
    }

    private static func isClearlyNotShelf(_ name: String) -> Bool {
        if ImageKind.shelfSelectionName(name) != nil { return false }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return !ImageKind.opensInShelf(URL(fileURLWithPath: name))
    }

    /// True when Finder's front window is the folder that contains this file.
    static func frontWindowContains(_ url: URL) -> Bool {
        guard let front = frontWindowFolder() else { return false }
        return sameFolder(front, url.deletingLastPathComponent())
    }

    private static func classify(_ urls: [URL]) -> Read {
        let photos = urls.compactMap(shelfURL)
        if photos.count == urls.count, !photos.isEmpty {
            SelectionCache.shared.note(photos)
            return .photos(photos)
        }
        SelectionCache.shared.note([])
        return .other
    }

    /// JPEG or PNG that is still on disk. A bak alias maps back to that file.
    private static func shelfURL(_ url: URL) -> URL? {
        let pathURL = ImageKind.posixFileURL(url)
        if ImageKind.opensInShelf(pathURL), FileManager.default.fileExists(atPath: pathURL.path) {
            return pathURL
        }
        return ImageKind.shelfFile(matching: pathURL.lastPathComponent, in: pathURL.deletingLastPathComponent())
    }

    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func frontWindowFolder() -> URL? {
        let source = """
        tell application "Finder"
            if (count of windows) is 0 then return ""
            set theTarget to target of front window as alias
            return POSIX path of theTarget
        end tell
        """
        guard let text = runAppleScript(source) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Selects `url` again only when the current highlight is not a real file.
    /// A different photo the user clicked is left alone.
    static func reselectIfUnresolved(_ url: URL) {
        let hit = accessibilitySelection()
        let wanted = ImageKind.posixFileURL(url).path
        if hit.urls.contains(where: { ImageKind.posixFileURL($0).path == wanted }) { return }
        if hit.urls.contains(where: { FileManager.default.fileExists(atPath: ImageKind.posixFileURL($0).path) }) {
            return
        }
        reselectIfNeeded(url)
    }

    /// Puts the highlight back on the file without leaving Space as a dead key.
    static func reselectIfNeeded(_ url: URL) {
        SelectionCache.shared.note([url])
        if accessibilitySelection().urls.contains(where: { $0.path == url.path }) { return }
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async {
            guard frontWindowContains(url) else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "on run argv\ntell application \"Finder\" to select (POSIX file (item 1 of argv) as alias)\nend run",
                "--",
                path
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    fileprivate static func accessibilitySelection() -> (urls: [URL], names: [String], folder: URL?) {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return ([], [], nil)
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        let window = browserWindow(of: app)
        let folder = window.flatMap(folderURL(of:))
        let focusedWindow: AXUIElement? = copy(app, kAXFocusedWindowAttribute as CFString)
        if focusedWindow.map(isFileBrowser) == true,
           let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute as CFString) {
            let walked = climbing(from: focused, folder: folder)
            if !walked.urls.isEmpty || !walked.names.isEmpty {
                return (walked.urls, walked.names, folder)
            }
        }
        if let window {
            var budget = 160
            let found = urlsInBrowser(window, folder: folder, depth: 8, budget: &budget)
            return (found.urls, found.names, folder)
        }
        return ([], [], folder)
    }

    /// Finder's key window is sometimes a system dialog (AirDrop) while the folder the user is looking at is behind it.
    private static func browserWindow(of app: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = copy(app, kAXFocusedWindowAttribute as CFString), isFileBrowser(focused) {
            return focused
        }
        if let main: AXUIElement = copy(app, kAXMainWindowAttribute as CFString), isFileBrowser(main) {
            return main
        }
        let browsers = elements(app, kAXWindowsAttribute as CFString).filter(isFileBrowser)
        if let title = frontFinderWindowTitle(),
           let match = browsers.first(where: { windowTitle($0) == title }) {
            return match
        }
        return browsers.first
    }

    private static func isFileBrowser(_ window: AXUIElement) -> Bool {
        let subrole: String = copy(window, kAXSubroleAttribute as CFString) ?? ""
        if subrole == "AXSystemDialog" { return false }
        if windowTitle(window) == "AirDrop" { return false }
        return subrole == "AXStandardWindow"
    }

    private static func windowTitle(_ window: AXUIElement) -> String {
        let title: String = copy(window, kAXTitleAttribute as CFString) ?? ""
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func frontWindowTitle() -> String? {
        frontFinderWindowTitle()
    }

    private static func frontFinderWindowTitle() -> String? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in info {
            guard (window[kCGWindowOwnerName as String] as? String) == "Finder" else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            let name = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty || name == "AirDrop" { continue }
            return name
        }
        return nil
    }

    private static func climbing(from focused: AXUIElement, folder: URL?) -> (urls: [URL], names: [String]) {
        var node: AXUIElement? = focused
        for _ in 0..<8 {
            guard let current = node else { break }
            let urls = selectedURLs(current, folder: folder)
            if !urls.isEmpty { return (urls, []) }
            let names = selectedNames(current)
            if !names.isEmpty { return ([], names) }
            node = copy(current, kAXParentAttribute as CFString)
        }
        return ([], [])
    }

    /// The sidebar is also a selection, so photo rows win over the selected folder.
    private static func urlsInBrowser(_ element: AXUIElement, folder: URL?, depth: Int, budget: inout Int) -> (urls: [URL], names: [String]) {
        var fallback: (urls: [URL], names: [String]) = ([], [])
        func walk(_ element: AXUIElement, depth: Int) -> (urls: [URL], names: [String])? {
            if budget <= 0 || depth < 0 { return nil }
            budget -= 1
            let urls = selectedURLs(element, folder: folder)
            if !urls.isEmpty, urls.allSatisfy(ImageKind.isPhoto) { return (urls, []) }
            let names = selectedNames(element)
            if !names.isEmpty, names.allSatisfy({ ImageKind.isPhoto(URL(fileURLWithPath: $0)) }) { return ([], names) }
            if fallback.urls.isEmpty, fallback.names.isEmpty {
                if !urls.isEmpty { fallback = (urls, []) }
                else if !names.isEmpty { fallback = ([], names) }
            }
            guard depth > 0 else { return nil }
            let role: String = copy(element, kAXRoleAttribute as CFString) ?? ""
            let containers: Set<String> = ["AXWindow", "AXSplitGroup", "AXScrollArea", "AXGroup", "AXList", "AXOutline", "AXBrowser", "AXLayoutArea", "AXUnknown", ""]
            guard containers.contains(role) else { return nil }
            for child in children(of: element).prefix(24) {
                if let found = walk(child, depth: depth - 1) { return found }
                if budget <= 0 { break }
            }
            return nil
        }
        return walk(element, depth: depth) ?? fallback
    }

    private static func selectedURLs(_ element: AXUIElement, folder: URL?) -> [URL] {
        selectedChildren(element).compactMap { resolve($0, folder: folder) }
    }

    private static func selectedNames(_ element: AXUIElement) -> [String] {
        selectedChildren(element).compactMap { fileName(of: $0, depth: 0) }
    }

    private static func resolve(_ element: AXUIElement, folder: URL?) -> URL? {
        if let url = url(of: element), let usable = usableURL(url, folder: folder) {
            return usable
        }
        guard let folder, let name = fileName(of: element, depth: 0) else { return nil }
        return namedFile(name, in: folder)
    }

    /// Keeps a real file URL. A file-reference URL is turned into a path when it
    /// still resolves. A missing file, or a `*.quickgrade-bak` name, falls through
    /// to the JPEG or PNG that is actually in the folder.
    private static func usableURL(_ url: URL, folder: URL?) -> URL? {
        let pathURL = ImageKind.posixFileURL(url)
        if FileManager.default.fileExists(atPath: pathURL.path) {
            if let folder,
               !ImageKind.opensInShelf(pathURL),
               let shelf = ImageKind.shelfFile(matching: pathURL.lastPathComponent, in: folder) {
                return shelf
            }
            return pathURL
        }
        let folder = folder ?? pathURL.deletingLastPathComponent()
        if let shelf = ImageKind.shelfFile(matching: url.lastPathComponent, in: folder) { return shelf }
        return ImageKind.shelfFile(matching: pathURL.lastPathComponent, in: folder)
    }

    private static func namedFile(_ name: String, in folder: URL) -> URL? {
        if let shelf = ImageKind.shelfFile(matching: name, in: folder) { return shelf }
        return resolveName(name, in: folder)
    }

    private static func fileName(of element: AXUIElement, depth: Int) -> String? {
        if depth > 2 { return nil }
        let keys = [kAXFilenameAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { $0 as CFString }
        for key in keys {
            if let name: String = copy(element, key) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.contains("/") { return trimmed }
            }
        }
        if let value: String = copy(element, kAXValueAttribute as CFString) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if ImageKind.shelfSelectionName(trimmed) != nil { return trimmed }
        }
        guard depth < 2 else { return nil }
        for child in children(of: element).prefix(6) {
            if let name = fileName(of: child, depth: depth + 1) { return name }
        }
        return nil
    }

    private static func folderURL(of window: AXUIElement) -> URL? {
        if let url: URL = copy(window, kAXDocumentAttribute as CFString) { return url }
        if let string: String = copy(window, kAXDocumentAttribute as CFString) {
            if let url = URL(string: string), url.isFileURL { return url }
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        }
        if let url: URL = copy(window, kAXURLAttribute as CFString) { return url }
        return nil
    }

    private static func selectedChildren(_ element: AXUIElement) -> [AXUIElement] {
        let children = elements(element, kAXSelectedChildrenAttribute as CFString)
        if !children.isEmpty { return children }
        return elements(element, "AXSelectedRows" as CFString)
    }

    private static func elements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return [] }
        if let list = value as? [AXUIElement] { return list }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        var result: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            result.append(unsafeBitCast(pointer, to: AXUIElement.self))
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let value else { return [] }
        if let list = value as? [AXUIElement] { return list }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        var result: [AXUIElement] = []
        let count = min(CFArrayGetCount(array), 24)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            result.append(unsafeBitCast(pointer, to: AXUIElement.self))
        }
        return result
    }

    private static func url(of element: AXUIElement, depth: Int = 0) -> URL? {
        if let url: URL = copy(element, kAXURLAttribute as CFString) { return url }
        if let string: String = copy(element, kAXURLAttribute as CFString), string.hasPrefix("/") {
            return URL(fileURLWithPath: string)
        }
        guard depth < 2 else { return nil }
        for child in children(of: element).prefix(4) {
            if let url = url(of: child, depth: depth + 1) { return url }
        }
        return nil
    }

    private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }
}

/// The view the front Finder window uses.
enum FinderView: Sendable {
    case icon, list, column, gallery
}

extension FinderSelection {
    static func frontWindowView() -> FinderView? {
        let source = """
        tell application "Finder"
            if (count of windows) is 0 then return ""
            return (current view of front window) as text
        end tell
        """
        guard let text = runAppleScript(source)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch text {
        case "icon view": return .icon
        case "list view": return .list
        case "column view": return .column
        case "flow view", "gallery view": return .gallery
        default: return nil
        }
    }

    /// The file Finder highlights right now, whatever its type. nil when nothing is selected.
    static func highlightedFile() -> URL? {
        let hit = accessibilitySelection()
        if let url = hit.urls.last { return ImageKind.posixFileURL(url) }
        if let name = hit.names.last, let folder = hit.folder {
            return resolveName(name, in: folder).map(ImageKind.posixFileURL)
        }
        return nil
    }
}

final class SelectionCache {
    static let shared = SelectionCache()
    private var stored: [URL] = []
    private var folder: URL?
    private var inflight = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "quickgrade.selection")

    var imageURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored.filter(ImageKind.isPhoto)
    }

    var folderURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return folder
    }

    func note(_ urls: [URL]) {
        lock.lock()
        stored = urls
        lock.unlock()
    }

    func noteFolder(_ url: URL) {
        lock.lock()
        folder = url
        lock.unlock()
    }

    private var cachedRead: FinderSelection.Read = .unknown
    private var cachedFolder: URL?
    private var cachedAt = Date.distantPast

    /// A read from the last moment or two, and only for the folder still on screen.
    func recent(matching folderHint: URL?) -> FinderSelection.Read? {
        lock.lock()
        let read = cachedRead
        let folder = cachedFolder
        let at = cachedAt
        lock.unlock()
        guard Date().timeIntervalSince(at) < 1.2, let folder else { return nil }
        if case .unknown = read { return nil }
        if case .empty = read { return nil }
        if let folderHint {
            guard same(folder, folderHint) else { return nil }
            return read
        }
        guard let title = FinderSelection.frontWindowTitle(),
              folder.lastPathComponent == title else { return nil }
        return read
    }

    func waitUntilSettled(timeout: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            lock.lock()
            let running = inflight
            lock.unlock()
            if !running { return }
            Thread.sleep(forTimeInterval: 0.008)
        }
    }

    func refreshIfFinderIsFront() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        lock.lock()
        if inflight {
            lock.unlock()
            return
        }
        inflight = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let hit = FinderSelection.accessibilitySelection()
            let read = FinderSelection.decision(urls: hit.urls, names: hit.names, folder: hit.folder)
            self.lock.lock()
            self.cachedRead = read
            if let folder = hit.folder { self.cachedFolder = folder }
            self.cachedAt = Date()
            self.inflight = false
            self.lock.unlock()
            if case .photos(let urls) = read { self.note(urls) }
        }
    }

    private func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
