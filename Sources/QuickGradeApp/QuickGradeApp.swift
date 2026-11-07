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
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    SpaceMonitor.shared.start()
                    self.model.refresh()
                }
            }
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
            if let mark = MenuMark.image {
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
            Button("Enable Accessibility…") { model.requestAccess() }
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
