import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@Observable
final class AppModel {
    var trusted = AXIsProcessTrusted()
    var opensAtLogin = SMAppService.mainApp.status == .enabled

    func refresh() {
        trusted = AXIsProcessTrusted()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// A switch left on for an older build of QuickGrade looks on in System Settings
    /// but no longer matches this app, so macOS keeps saying no. Clearing QuickGrade's own
    /// entry first means the prompt adds a fresh one, and one flip of the switch works.
    func requestAccess() {
        guard !AXIsProcessTrusted() else {
            refresh()
            return
        }
        if let id = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", id]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        SpaceMonitor.shared.start()
        refresh()
    }

    func toggleLogin() {
        do {
            if opensAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Login items can fail until the app lives in a stable folder.
        }
        refresh()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SpaceMonitor.shared.start()
        registerLoginItemIfInstalled()
        model.refresh()
        if !model.trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.model.requestAccess()
            }
        }
        // Without Accessibility, Space never reaches QuickGrade and nothing happens at all.
        // Keep checking, so the guide shows whenever the switch is off and leaves once it's on.
        AccessGuide.shared.model = model
        AccessGuide.shared.update()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let trusted = AXIsProcessTrusted()
            if trusted != self.model.trusted {
                self.model.refresh()
                if trusted { SpaceMonitor.shared.start() }
            }
            AccessGuide.shared.update()
        }
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = arguments.first {
            GradeController.shared.open(urls: [URL(fileURLWithPath: path)])
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SpaceMonitor.shared.start()
        model.refresh()
    }

    func applicationDidResignActive(_ notification: Notification) {
        GradeController.shared.appResigned()
    }

    /// Open at login only works once the app lives in an Applications folder.
    /// The flag keeps a later "Open at Login: Off" from turning itself back on.
    private func registerLoginItemIfInstalled() {
        let path = Bundle.main.bundlePath
        let homeApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path + "/"
        guard path.hasPrefix("/Applications/") || path.hasPrefix(homeApps) else { return }
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard SMAppService.mainApp.status == .notRegistered else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            // The menu item can turn it on later if this is declined.
        }
    }
}

@main
struct QuickGradeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            if !delegate.model.trusted {
                // A warning in the menu bar while Space can't work.
                Image(systemName: "exclamationmark.triangle")
            } else if let mark = MenuMark.image {
                Image(nsImage: mark)
            } else {
                Image(systemName: "camera.filters")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text("Select a photo in Finder and press Space")
        Divider()
        if model.trusted {
            Label("Accessibility is on", systemImage: "checkmark.circle")
        } else {
            Text("Space won't open photos until Accessibility is on")
            Button("Turn On Accessibility…") {
                model.requestAccess()
                AccessGuide.openSettings()
            }
        }
        Button(model.opensAtLogin ? "Open at Login: On" : "Open at Login") {
            model.toggleLogin()
        }
        Divider()
        Button("Quit QuickGrade") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private enum MenuMark {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// A small window that says why Space does nothing yet and opens the right settings pane.
/// It shows while Accessibility is off and closes itself once the switch is on.
@MainActor
final class AccessGuide {
    static let shared = AccessGuide()
    var model: AppModel?
    private var window: NSPanel?
    private var dismissedUntil = Date.distantPast

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func update() {
        if AXIsProcessTrusted() {
            window?.orderOut(nil)
            return
        }
        guard Date() > dismissedUntil else { return }
        let panel = window ?? makeWindow()
        if !panel.isVisible {
            panel.center()
            panel.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: AccessGuideView(
            onOpen: {
                self.model?.requestAccess()
                AccessGuide.openSettings()
            },
            onLater: {
                // Out of the way for a while. It comes back, since nothing works without it.
                self.dismissedUntil = Date().addingTimeInterval(10 * 60)
                self.window?.orderOut(nil)
            }
        ))
        window = panel
        return panel
    }
}

private struct AccessGuideView: View {
    let onOpen: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                Text("Turn on Accessibility for QuickGrade")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Until it's on, pressing Space in Finder can't open your photos. In the list, switch QuickGrade on. If it already looks on, remove it with the minus button and add it again: macOS forgets the switch after an update.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Later", action: onLater)
                Button("Open Settings", action: onOpen)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 380)
    }
}
