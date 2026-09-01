import AppKit
import CoreText
import FounderOfficeCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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
    private var personalization: PersonalizationStore?
    private var workspaceSession: WorkspaceSession?
    private var notchController: NotchWindowController?
    private var updateController: FounderOfficeUpdateController?
    private var onboardingStore: FirstRunOnboardingStore?
    private var onboardingWindowController: FirstRunOnboardingWindowController?
    private var statusItem: NSStatusItem?
    private var motionCaptureTimer: Timer?
    private let runtimeHealth = RuntimeHealthCoordinator()
    private var safeModeIncidentID: UUID?
    private var isSafeMode = false
    private var isOnboarding = false
    private var recoveryState: WorkspaceRecoveryState?
    private var workspaceRootURL: URL?
    private var didMarkRuntimeReady = false
    private let supportReportStorage = SupportReportStorage()
    private var onboardingDefaults: UserDefaults = .standard
    #if !FOUNDER_OFFICE_DISTRIBUTION
    private var onboardingUITestDefaultsSuiteName: String?
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if !FOUNDER_OFFICE_DISTRIBUTION
        let arguments = CommandLine.arguments
        if arguments.contains("--snapshot")
            || arguments.contains("--motion-frames")
            || arguments.contains("--motion-reversal-frames")
            || arguments.contains("--ui-testing")
            || arguments.contains("--ui-testing-onboarding") {
            return .terminateNow
        }
        #endif

        guard let notchController else { return .terminateNow }
        guard notchController.hasUnsavedAppearanceChanges
                || notchController.hasPendingWorkspaceWrites else { return .terminateNow }
        Task {
            let shouldTerminate = await notchController.resolveUnsavedAppearanceForTermination()
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.contains("--unregister-login") {
            unregisterLaunchAtLoginForMigration()
            NSApp.terminate(nil)
            return
        }

        #if FOUNDER_OFFICE_DISTRIBUTION
        let isCaptureLaunch = false
        let launchDisposition = runtimeHealth.beginLaunch(trackCrashLoop: true)
        #else
        let isStandardUITestLaunch = arguments.contains("--ui-testing")
        let isOnboardingUITestLaunch = arguments.contains("--ui-testing-onboarding")
        let isUITestLaunch = isStandardUITestLaunch || isOnboardingUITestLaunch
        let isCaptureLaunch = arguments.contains("--preview")
            || arguments.contains("--snapshot")
            || arguments.contains("--motion-frames")
            || arguments.contains("--motion-reversal-frames")
            || isStandardUITestLaunch
        if isOnboardingUITestLaunch {
            let suiteName = "com.manish.openloops.onboarding-ui-test.\(ProcessInfo.processInfo.processIdentifier)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Unable to create isolated onboarding UI-test preferences.")
            }
            defaults.removePersistentDomain(forName: suiteName)
            onboardingDefaults = defaults
            onboardingUITestDefaultsSuiteName = suiteName
        }
        let launchDisposition = runtimeHealth.beginLaunch(
            trackCrashLoop: !(isCaptureLaunch || isOnboardingUITestLaunch)
        )
        #endif
        isSafeMode = launchDisposition.isSafeMode
        safeModeIncidentID = launchDisposition.incidentID

        #if FOUNDER_OFFICE_DISTRIBUTION
        NSApp.setActivationPolicy(.accessory)
        #else
        NSApp.setActivationPolicy(isUITestLaunch ? .regular : .accessory)
        #endif
        if isSafeMode {
            configureStatusItem()
            DispatchQueue.main.async { [weak self] in
                self?.showSafeModeAlert()
            }
            return
        }

        registerBundledFonts()

        let rootURL = WorkspaceLocator.openLoopsRoot
        workspaceRootURL = rootURL
        #if FOUNDER_OFFICE_DISTRIBUTION
        let expectedWorkspaceID = FirstRunOnboardingStore.persistedWorkspaceID(defaults: onboardingDefaults)
        #else
        let expectedWorkspaceID = isCaptureLaunch
            ? nil
            : FirstRunOnboardingStore.persistedWorkspaceID(defaults: onboardingDefaults)
        #endif
        Task { [weak self] in
            let preparedBootstrap = await Task.detached(priority: .userInitiated) {
                WorkspaceBootstrapCoordinator.inspect(
                    rootURL: rootURL,
                    expectedWorkspaceID: expectedWorkspaceID
                )
            }.value
            await self?.continueBootstrap(
                preparedBootstrap,
                rootURL: rootURL,
                arguments: arguments,
                isCaptureLaunch: isCaptureLaunch
            )
        }
    }

    private func continueBootstrap(
        _ preparedBootstrap: PreparedWorkspaceBootstrap,
        rootURL: URL,
        arguments: [String],
        isCaptureLaunch: Bool
    ) async {
        let workspaceID: UUID
        let identityNeedsCommit: Bool
        switch preparedBootstrap.decision {
        case let .initializeNew(id):
            workspaceID = id
            identityNeedsCommit = true
        case let .useExisting(id, needsIdentityCommit):
            workspaceID = id
            identityNeedsCommit = needsIdentityCommit
        case let .requireRecovery(affectedComponents):
            recoveryState = WorkspaceRecoveryState(
                affectedComponents: affectedComponents,
                preservedCopyNames: preparedBootstrap.preservedIdentityCopyName.map { [$0] } ?? []
            )
            configureStatusItem()
            showRecoveryRequiredAlert()
            return
        }

        await openWorkspaceAndContinue(
            rootURL: rootURL,
            workspaceID: workspaceID,
            identityNeedsCommit: identityNeedsCommit,
            preparedBootstrap: preparedBootstrap,
            arguments: arguments,
            isCaptureLaunch: isCaptureLaunch
        )
    }

    private func openWorkspaceAndContinue(
        rootURL: URL,
        workspaceID: UUID,
        identityNeedsCommit: Bool,
        preparedBootstrap: PreparedWorkspaceBootstrap,
        arguments: [String],
        isCaptureLaunch: Bool
    ) async {
        do {
            let session = try await WorkspaceSession.open(
                rootURL: rootURL,
                workspaceID: workspaceID,
                initialSnapshot: WorkspaceSession.freshSnapshot
            )

            if identityNeedsCommit {
                let identityURL = preparedBootstrap.identityURL
                try await Task.detached(priority: .userInitiated) {
                    try WorkspaceBootstrapCoordinator.commitIdentity(
                        workspaceID: workspaceID,
                        to: identityURL
                    )
                }.value
            }

            workspaceSession = session
            let store = OpenLoopStore(session: session)
            let personalization = PersonalizationStore(session: session)
            self.store = store
            self.personalization = personalization

            #if FOUNDER_OFFICE_DISTRIBUTION
            let firstRunStore: FirstRunOnboardingStore? = FirstRunOnboardingStore(
                workspaceExistedBeforeLaunch: preparedBootstrap.workspaceExistedBeforeLaunch,
                workspaceID: workspaceID,
                defaults: onboardingDefaults
            )
            #else
            let firstRunStore: FirstRunOnboardingStore? = isCaptureLaunch ? nil : FirstRunOnboardingStore(
                workspaceExistedBeforeLaunch: preparedBootstrap.workspaceExistedBeforeLaunch,
                workspaceID: workspaceID,
                defaults: onboardingDefaults
            )
            #endif
            onboardingStore = firstRunStore

            if let onboardingStore = firstRunStore, !onboardingStore.isComplete {
                isOnboarding = true
                configureStatusItem()
                #if FOUNDER_OFFICE_DISTRIBUTION
                let onboardingCalendarMode = CalendarProvider.Mode.live
                let currentLaunchAtLogin = { SMAppService.mainApp.status == .enabled }
                let updateLaunchAtLogin: (Bool) throws -> Bool = { [weak self] enabled in
                    guard let self else { return false }
                    return try self.setLaunchAtLogin(enabled)
                }
                #else
                let isOnboardingUITestLaunch = arguments.contains("--ui-testing-onboarding")
                let onboardingCalendarMode: CalendarProvider.Mode = isOnboardingUITestLaunch
                    ? .syntheticPreview
                    : .live
                let currentLaunchAtLogin = {
                    isOnboardingUITestLaunch ? false : SMAppService.mainApp.status == .enabled
                }
                let updateLaunchAtLogin: (Bool) throws -> Bool = isOnboardingUITestLaunch
                    ? { enabled in enabled }
                    : { [weak self] enabled in
                        guard let self else { return false }
                        return try self.setLaunchAtLogin(enabled)
                    }
                #endif
                let onboardingWindow = FirstRunOnboardingWindowController(
                    stateStore: onboardingStore,
                    taskStore: store,
                    personalization: personalization,
                    calendarMode: onboardingCalendarMode,
                    currentLaunchAtLogin: currentLaunchAtLogin,
                    setLaunchAtLogin: updateLaunchAtLogin,
                    onComplete: { [weak self] storageMode in
                        self?.completeOnboarding(storageMode: storageMode)
                    }
                )
                onboardingWindowController = onboardingWindow
                onboardingWindow.show()
                DispatchQueue.main.async { [weak self] in self?.markRuntimeReady() }
                return
            }

            #if FOUNDER_OFFICE_DISTRIBUTION
            let storageMode = onboardingStore?.storageMode ?? .localOnly
            let calendarMode = CalendarProvider.Mode.live
            #else
            let storageMode = isCaptureLaunch
                ? FirstRunStorageMode.localOnly
                : onboardingStore?.storageMode ?? .localOnly
            let calendarMode = isCaptureLaunch ? CalendarProvider.Mode.syntheticPreview : .live
            #endif
            let notchController = activateWorkspace(
                store: store,
                personalization: personalization,
                storageMode: storageMode,
                calendarMode: calendarMode
            )

            #if FOUNDER_OFFICE_DISTRIBUTION
            reconcileLaunchAtLoginPreference()
            #else
            if !isCaptureLaunch {
                reconcileLaunchAtLoginPreference()
            }
            #endif

            markRuntimeReady()

            #if !FOUNDER_OFFICE_DISTRIBUTION
            configureCaptureIfRequested(
                arguments: arguments,
                controller: notchController
            )
            #endif
        } catch {
            recoveryState = WorkspaceRecoveryState(affectedComponents: WorkspaceStorageComponent.allCases)
            configureStatusItem()
            AppDiagnostics.failure(.moveStoreLoad, category: .storage, error: error)
            showRecoveryRequiredAlert()
        }
    }

    #if !FOUNDER_OFFICE_DISTRIBUTION
    private func configureCaptureIfRequested(
        arguments: [String],
        controller: NotchWindowController
    ) {
        if arguments.contains("--ui-testing") {
            controller.showSnapshot()
            NSApp.activate(ignoringOtherApps: true)
        } else if arguments.contains("--snapshot") {
            controller.showSnapshot()
        } else if arguments.contains("--preview")
                    || arguments.contains("--motion-frames")
                    || arguments.contains("--motion-reversal-frames") {
            controller.show(preview: true)
        }

        if let snapshotIndex = arguments.firstIndex(of: "--snapshot"),
           arguments.indices.contains(snapshotIndex + 1) {
            let outputURL = URL(fileURLWithPath: arguments[snapshotIndex + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                do {
                    try controller.capture(to: outputURL)
                    NSApp.terminate(nil)
                } catch {
                    AppDiagnostics.failure(.snapshotCapture, category: .application, error: error)
                    NSApp.terminate(nil)
                }
            }
        }

        if let motionIndex = arguments.firstIndex(of: "--motion-frames"),
           arguments.indices.contains(motionIndex + 1) {
            startMotionCapture(
                controller: controller,
                framesURL: URL(fileURLWithPath: arguments[motionIndex + 1], isDirectory: true)
            )
        }

        if let reversalIndex = arguments.firstIndex(of: "--motion-reversal-frames"),
           arguments.indices.contains(reversalIndex + 1) {
            startReversalCapture(
                controller: controller,
                framesURL: URL(fileURLWithPath: arguments[reversalIndex + 1], isDirectory: true)
            )
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        // A user- or AppKit-approved quit during asynchronous bootstrap is not
        // a crash. Clear only this launch's in-progress bit; prior failures and
        // an active safe-mode latch remain intact.
        runtimeHealth.markCleanTermination()
        motionCaptureTimer?.invalidate()
        motionCaptureTimer = nil
        notchController?.prepareForTermination()
        updateController?.cancel()
        workspaceSession?.stop()
        store?.stop()
        personalization?.stop()
        runtimeHealth.stop()
        #if !FOUNDER_OFFICE_DISTRIBUTION
        if let onboardingUITestDefaultsSuiteName,
           let defaults = UserDefaults(suiteName: onboardingUITestDefaultsSuiteName) {
            defaults.removePersistentDomain(forName: onboardingUITestDefaultsSuiteName)
        }
        #endif
    }

    @discardableResult
    private func activateWorkspace(
        store: OpenLoopStore,
        personalization: PersonalizationStore,
        storageMode _: FirstRunStorageMode,
        calendarMode: CalendarProvider.Mode = .live
    ) -> NotchWindowController {
        let controller = NotchWindowController(
            store: store,
            personalization: personalization,
            calendarMode: calendarMode
        )
        notchController = controller
        updateController?.cancel()
        updateController = FounderOfficeUpdateController(notchController: controller)
        if statusItem == nil {
            configureStatusItem()
        } else {
            updateStatusItemAppearance()
        }
        return controller
    }

    private func completeOnboarding(storageMode: FirstRunStorageMode) {
        guard let store, let personalization else { return }
        let currentRecovery = store.recoveryState.merging(personalization.recoveryState)
        guard !currentRecovery.requiresRecovery else {
            recoveryState = currentRecovery
            isOnboarding = false
            onboardingWindowController?.close()
            onboardingWindowController = nil
            updateStatusItemAppearance()
            showRecoveryRequiredAlert()
            return
        }

        onboardingWindowController?.close()
        onboardingWindowController = nil
        isOnboarding = false

        let controller = activateWorkspace(
            store: store,
            personalization: personalization,
            storageMode: storageMode
        )
        reconcileLaunchAtLoginPreference()
        controller.show(manual: true)
        updateController?.startAutomaticCheckAfterRuntimeReady()
    }

    private func markRuntimeReady() {
        guard !didMarkRuntimeReady else { return }
        didMarkRuntimeReady = true
        runtimeHealth.markReady()
        if !isOnboarding {
            updateController?.startAutomaticCheckAfterRuntimeReady()
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

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
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
                    self?.motionCaptureTimer?.invalidate()
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

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
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
                    self?.motionCaptureTimer?.invalidate()
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
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        let symbolName: String
        let toolTip: String
        if isSafeMode {
            symbolName = "exclamationmark.shield"
            toolTip = "\(appName) — Safe Mode"
        } else if recoveryState?.requiresRecovery == true {
            symbolName = "exclamationmark.triangle"
            toolTip = "\(appName) — Recovery Required"
        } else if isOnboarding {
            symbolName = "sparkles"
            toolTip = "Finish setting up \(appName)"
        } else {
            symbolName = "checklist"
            toolTip = appName
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        statusItem?.button?.toolTip = toolTip
    }

    private func reconcileLaunchAtLoginPreference() {
        guard #available(macOS 13.0, *) else { return }
        // Never fight a choice made in System Settings. Registration only
        // happens after an explicit in-app action; launches merely mirror the
        // current macOS state into our preference.
        UserDefaults.standard.set(
            SMAppService.mainApp.status == .enabled,
            forKey: launchAtLoginPreferenceKey
        )
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
        if isSafeMode {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showStatusMenu()
            } else {
                showSafeModeAlert()
            }
            return
        }

        if recoveryState?.requiresRecovery == true {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showStatusMenu()
            } else {
                showRecoveryRequiredAlert()
            }
            return
        }

        if isOnboarding {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showStatusMenu()
            } else {
                onboardingWindowController?.show()
            }
            return
        }

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
        menu.identifier = TransientPresentationCoordinator.statusMenuIdentifier

        if isSafeMode {
            let status = NSMenuItem(title: "Safe Mode Active", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)

            if safeModeIncidentID != nil {
                let incidentItem = NSMenuItem(
                    title: "Copy Incident ID",
                    action: #selector(copySafeModeIncidentID),
                    keyEquivalent: ""
                )
                incidentItem.target = self
                menu.addItem(incidentItem)

                let diagnosticItem = NSMenuItem(
                    title: "Save Redacted Crash Diagnostic…",
                    action: #selector(saveSafeModeDiagnostic),
                    keyEquivalent: ""
                )
                diagnosticItem.target = self
                menu.addItem(diagnosticItem)
            }

            let retryItem = NSMenuItem(
                title: "Retry Normal Mode…",
                action: #selector(retryNormalMode),
                keyEquivalent: ""
            )
            retryItem.target = self
            menu.addItem(retryItem)
            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }

        if recoveryState?.requiresRecovery == true {
            let status = NSMenuItem(title: "Recovery Required", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)

            let revealItem = NSMenuItem(title: "Reveal Preserved Files", action: #selector(revealRecoveryFolder), keyEquivalent: "")
            revealItem.target = self
            menu.addItem(revealItem)
            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }

        if isOnboarding {
            let setupItem = NSMenuItem(title: "Finish Setup", action: #selector(showOnboarding), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }

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

        menu.addItem(.separator())
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

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

    @objc private func showOnboarding() {
        onboardingWindowController?.show()
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

    @objc private func revealRecoveryFolder() {
        guard let rootURL = workspaceRootURL else { return }
        NSWorkspace.shared.open(rootURL)
    }

    @objc private func checkForUpdates() {
        updateController?.checkManually()
    }

    @objc private func copySafeModeIncidentID() {
        guard let incidentID = safeModeIncidentID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(incidentID.uuidString.lowercased(), forType: .string)
    }

    @objc private func saveSafeModeDiagnostic() {
        guard isSafeMode, let incidentID = safeModeIncidentID else { return }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let report = RedactedCrashStateReport(
            incidentID: incidentID,
            capturedAt: Date(),
            consecutivePreReadyFailures: runtimeHealth.disposition.consecutivePreReadyFailures,
            metadata: SupportReportMetadata(
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "development",
                buildNumber: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "development",
                operatingSystemMajor: version.majorVersion,
                operatingSystemMinor: version.minorVersion,
                operatingSystemPatch: version.patchVersion,
                architecture: Self.supportArchitecture
            )
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "founders-office-crash-state.json"
        panel.message = "Saves ten allow-listed crash-state fields. The workspace stays closed."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await supportReportStorage.save(report, to: destination)
            } catch {
                AppDiagnostics.failure(
                    .safeModeDiagnosticSave,
                    category: .storage,
                    error: error
                )
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t save the crash diagnostic"
                alert.informativeText = "Choose another location and try again."
                alert.runModal()
            }
        }
    }

    @objc private func retryNormalMode() {
        let alert = NSAlert()
        alert.messageText = "Retry normal mode?"
        alert.informativeText = "Founder’s Office will clear this build’s crash-loop marker and quit. Reopen the app to retry. Resetting the marker does not change your workspace."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        performNormalModeRetry()
    }

    private func performNormalModeRetry() {
        runtimeHealth.prepareExplicitRetry()
        NSApp.terminate(nil)
    }

    private func showSafeModeAlert() {
        let alert = NSAlert()
        alert.messageText = "Founder’s Office is in safe mode"
        alert.informativeText = "Three launches did not reach the ready checkpoint, so Founder’s Office kept your workspace closed and unchanged. Reset this build’s marker and quit, then reopen the app—or stay in safe mode and use the menu bar for diagnostics."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset and Quit")
        alert.addButton(withTitle: "Stay in Safe Mode")
        DispatchQueue.main.async { [weak self] in self?.markRuntimeReady() }
        if alert.runModal() == .alertFirstButtonReturn {
            performNormalModeRetry()
        }
    }

    private func showRecoveryRequiredAlert() {
        guard let recoveryState, recoveryState.requiresRecovery else { return }
        let components = recoveryState.affectedComponents.map(\.title).joined(separator: " and ")
        let preservation = recoveryState.preservedCopyNames.isEmpty
            ? "Existing files were left untouched."
            : "A byte-for-byte Recovery copy was preserved."
        let alert = NSAlert()
        alert.messageText = "Your workspace needs recovery"
        alert.informativeText = "Founder’s Office found missing or unreadable \(components). "
            + "\(preservation) Setup stopped before iCloud sync, and no replacement workspace was written. "
            + "Reveal the data folder to inspect the workspace and any Recovery copies."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reveal Data Folder")
        alert.addButton(withTitle: "Quit")
        DispatchQueue.main.async { [weak self] in self?.markRuntimeReady() }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            revealRecoveryFolder()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) throws -> Bool {
        guard #available(macOS 13.0, *) else { return false }

        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }

        let actualValue = SMAppService.mainApp.status == .enabled
        if actualValue == enabled {
            UserDefaults.standard.set(actualValue, forKey: launchAtLoginPreferenceKey)
        }
        return actualValue
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            let shouldEnable = SMAppService.mainApp.status != .enabled
            _ = try setLaunchAtLogin(shouldEnable)
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

    private static var supportArchitecture: SupportArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }
}
