import AppKit
import ApplicationServices

final class SpaceMonitor {
    static let shared = SpaceMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var startedAux = false
    /// Set when this press must not reach Finder, so the matching key-up is swallowed too.
    private var consumeRelease = false

    var isRunning: Bool { tap != nil }

    func start() {
        guard AXIsProcessTrusted() else { return }
        if tap == nil {
            installTap()
        }
        guard !startedAux else { return }
        startedAux = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            SelectionCache.shared.refreshIfFinderIsFront()
            if let tap = self?.tap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { _ in
            SelectionCache.shared.refreshIfFinderIsFront()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.finder" {
                SelectionCache.shared.refreshIfFinderIsFront()
            }
        }
    }

    private func installTap() {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, user in
                guard let user else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SpaceMonitor>.fromOpaque(user).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: userInfo
        )
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        SelectionCache.shared.refreshIfFinderIsFront()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == 6, type == .keyDown {
            let flags = event.flags
            let extra = flags.intersection([.maskAlternate, .maskControl])
            if flags.contains(.maskCommand), extra.isEmpty {
                let redo = flags.contains(.maskShift)
                let handled: Bool
                if Thread.isMainThread {
                    handled = MainActor.assumeIsolated { GradeController.shared.historyKey(redo: redo) }
                } else {
                    handled = DispatchQueue.main.sync {
                        MainActor.assumeIsolated { GradeController.shared.historyKey(redo: redo) }
                    }
                }
                if handled { return nil }
            }
        }
        guard keycode == 49, type == .keyDown || type == .keyUp else {
            return deliver(event, pass: true)
        }
        let blocked: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if event.flags.intersection(blocked) != [] {
            return deliver(event, pass: true)
        }
        if type == .keyUp {
            if consumeRelease {
                consumeRelease = false
                return deliver(event, pass: false)
            }
            return deliver(event, pass: true)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 1 {
            return deliver(event, pass: !consumeRelease)
        }
        let action: SpaceAction
        if Thread.isMainThread {
            action = MainActor.assumeIsolated { GradeController.shared.spaceAction() }
        } else {
            action = DispatchQueue.main.sync {
                MainActor.assumeIsolated { GradeController.shared.spaceAction() }
            }
        }
        switch action {
        case .ignore:
            return deliver(event, pass: true)
        case .swallow:
            consumeRelease = true
            return deliver(event, pass: false)
        case .close:
            consumeRelease = true
            DispatchQueue.main.async { GradeController.shared.close(restoreSelection: true) }
            return deliver(event, pass: false)
        case .open(let urls):
            consumeRelease = true
            DispatchQueue.main.async { GradeController.shared.open(urls: urls, keepGrade: false) }
            return deliver(event, pass: false)
        case .resolve(let names):
            consumeRelease = true
            DispatchQueue.main.async { GradeController.shared.openFinderNames(names) }
            return deliver(event, pass: false)
        }
    }

    /// If the tap timed out, macOS already delivered this event. Returning it again toggles Quick Look twice.
    private func deliver(_ event: CGEvent, pass: Bool) -> Unmanaged<CGEvent>? {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return nil
        }
        return pass ? Unmanaged.passUnretained(event) : nil
    }
}
