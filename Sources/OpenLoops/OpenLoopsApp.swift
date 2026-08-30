import AppKit
import CoreText
import ServiceManagement
import SwiftUI

@main
struct FoundersOfficeApp: App {
    @NSApplicationDelegateAdaptor(FoundersOfficeAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class FoundersOfficeAppDelegate: NSObject, NSApplicationDelegate {
    private let appName = "Founder's Office"
    private let launchAtLoginPreferenceKey = "FoundersOfficeLaunchAtLoginEnabled"
    private var store: OpenLoopStore?
    private var cloudSyncBridge: CloudSyncBridge?
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var motionCaptureTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NSApp.setActivationPolicy(.accessory)

        let arguments = CommandLine.arguments
        if arguments.contains("--unregister-login") {
            unregisterLaunchAtLoginForMigration()
            NSApp.terminate(nil)
            return
        }

        let store = OpenLoopStore()
        let notchController = NotchWindowController(store: store)
        self.store = store
        self.notchController = notchController

        if Bundle.main.object(forInfoDictionaryKey: "FounderOfficeCloudEnabled") as? Bool == true {
            let bridge = CloudSyncBridge(rootURL: store.rootURL)
            bridge.start()
            cloudSyncBridge = bridge
        }

        configureStatusItem()

        if !arguments.contains("--preview") && !arguments.contains("--snapshot") {
            ensureLaunchAtLogin()
        }

        if arguments.contains("--snapshot") {
            notchController.showSnapshot()
        } else if arguments.contains("--preview") || arguments.contains("--motion-frames") || arguments.contains("--motion-reversal-frames") {
            notchController.show(preview: true)
        }

        if let snapshotIndex = arguments.firstIndex(of: "--snapshot"),
           arguments.indices.contains(snapshotIndex + 1) {
            let outputURL = URL(fileURLWithPath: arguments[snapshotIndex + 1])
            // Snapshot mode bypasses the spring; this pause is only for initial
            // file loading and SwiftUI layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                do {
                    try notchController.capture(to: outputURL)
                    NSApp.terminate(nil)
                } catch {
                    AppDiagnostics.failure(.snapshotCapture, category: .application, error: error)
                    NSApp.terminate(nil)
                }
            }
        }

        if let motionIndex = arguments.firstIndex(of: "--motion-frames"),
           arguments.indices.contains(motionIndex + 1) {
            let framesURL = URL(fileURLWithPath: arguments[motionIndex + 1], isDirectory: true)
            startMotionCapture(controller: notchController, framesURL: framesURL)
        }

        if let reversalIndex = arguments.firstIndex(of: "--motion-reversal-frames"),
           arguments.indices.contains(reversalIndex + 1) {
            let framesURL = URL(fileURLWithPath: arguments[reversalIndex + 1], isDirectory: true)
            startReversalCapture(controller: notchController, framesURL: framesURL)
        }
    }

    private func registerBundledFonts() {
        guard let fontURL = Bundle.main.url(
            forResource: "InstrumentSerif-Regular",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else {
            AppDiagnostics.failure(
                .fontResourceLookup,
                category: .resources,
                domain: "FounderOffice.Resources",
                code: 1
            )
            return
        }

        var registrationError: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError),
           let error = registrationError?.takeRetainedValue() {
            AppDiagnostics.failure(.fontRegistration, category: .resources, error: error as Error)
        }
    }

    private func startMotionCapture(controller: NotchWindowController, framesURL: URL) {
        do {
            try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        } catch {
            AppDiagnostics.failure(.motionCaptureDirectoryCreate, category: .application, error: error)
            NSApp.terminate(nil)
            return
        }

        let startedAt = Date()
        var frameNumber = 0
        var collapseStarted = false

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(startedAt)

                if elapsed >= 0.68, !collapseStarted {
                    collapseStarted = true
                    controller.hide(force: true)
                }

                let frameURL = framesURL.appendingPathComponent(String(format: "frame-%03d.png", frameNumber))
                try? controller.capture(to: frameURL)
                frameNumber += 1

                if elapsed >= 1.18 {
                    timer.invalidate()
                    self?.motionCaptureTimer = nil
                    NSApp.terminate(nil)
                }
            }
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        motionCaptureTimer = timer
    }

    private func startReversalCapture(controller: NotchWindowController, framesURL: URL) {
        do {
            try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        } catch {
            AppDiagnostics.failure(.reversalCaptureDirectoryCreate, category: .application, error: error)
            NSApp.terminate(nil)
            return
        }

        let startedAt = Date()
        var frameNumber = 0
        var collapseStarted = false
        var reversalStarted = false
        var finalCollapseStarted = false

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(startedAt)

                if elapsed >= 0.50, !collapseStarted {
                    collapseStarted = true
                    controller.hide(force: true)
                }

                if elapsed >= 0.62, !reversalStarted {
                    reversalStarted = true
                    controller.show(preview: true)
                }

                if elapsed >= 1.12, !finalCollapseStarted {
                    finalCollapseStarted = true
                    controller.hide(force: true)
                }

                let frameURL = framesURL.appendingPathComponent(String(format: "frame-%03d.png", frameNumber))
                try? controller.capture(to: frameURL)
                frameNumber += 1

                if elapsed >= 1.50 {
                    timer.invalidate()
                    self?.motionCaptureTimer = nil
                    NSApp.terminate(nil)
                }
            }
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        motionCaptureTimer = timer
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: appName)
        item.button?.toolTip = appName
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func ensureLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let defaults = UserDefaults.standard
        // Launch at login is always opt-in. The menu item (and future onboarding)
        // records the user's choice before registration is attempted.
        guard defaults.bool(forKey: launchAtLoginPreferenceKey) else { return }

        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            AppDiagnostics.failure(.launchAtLoginRegister, category: .lifecycle, error: error)
        }
    }

    private func unregisterLaunchAtLoginForMigration() {
        guard #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            AppDiagnostics.failure(.launchAtLoginUnregister, category: .lifecycle, error: error)
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            notchController?.toggle()
            return
        }

        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            notchController?.toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open \(appName)", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let reloadItem = NSMenuItem(title: "Refresh Tasks", action: #selector(reloadStore), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let contextItem = NSMenuItem(title: "Open Context File", action: #selector(openContext), keyEquivalent: "")
        contextItem.target = self
        menu.addItem(contextItem)

        let folderItem = NSMenuItem(title: "Reveal Data Folder", action: #selector(revealDataFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        if #available(macOS 13.0, *) {
            menu.addItem(.separator())
            let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openPanel() {
        notchController?.show(manual: true)
    }

    @objc private func reloadStore() {
        store?.reload()
    }

    @objc private func openContext() {
        store?.openContextFile()
    }

    @objc private func revealDataFolder() {
        store?.revealDataFolder()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: launchAtLoginPreferenceKey)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: launchAtLoginPreferenceKey)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change launch-at-login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
