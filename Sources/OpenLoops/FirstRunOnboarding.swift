import AppKit
import Combine
import FounderOfficeCore
import ServiceManagement
import SwiftUI

private func onboardingSystemFont(
    _ role: FounderTextRole,
    weight: Font.Weight = .regular
) -> Font {
    .system(size: CGFloat(FounderTypeScale.points(for: role)), weight: weight)
}

private func onboardingDisplayFont(_ role: FounderTextRole) -> Font {
    .custom(
        "Instrument Serif",
        size: CGFloat(FounderTypeScale.points(for: role)),
        relativeTo: role == .primaryTitle ? .largeTitle : .body
    )
}

enum FirstRunStorageMode: String, Codable {
    case localOnly
    /// Read-only compatibility for onboarding records written before the
    /// transactional Supabase sync boundary. The retired CloudKit writer is
    /// never re-enabled from this value.
    case iCloud
}

private enum FirstRunPermissionChoice: String, Codable {
    case connected
    case skipped
}

enum FirstRunStep: Int, Codable, CaseIterable {
    case welcome
    case storage
    case calendar
    case startup
    case firstMove
    case rehearsal

    var symbolName: String {
        switch self {
        case .welcome: return "person.crop.circle"
        case .storage: return "externaldrive"
        case .calendar: return "calendar"
        case .startup: return "power"
        case .firstMove: return "checklist"
        case .rehearsal: return "macbook"
        }
    }
}

private struct FirstRunOnboardingState: Codable {
    static let currentVersion = 3

    var schemaVersion = currentVersion
    var completedVersion: Int?
    var completedAt: Date?
    var stepRawValue = FirstRunStep.welcome.rawValue
    var workspaceID: UUID?
    var preferredName: String?
    var storageMode: FirstRunStorageMode?
    var calendarChoice: FirstRunPermissionChoice?
    var launchAtLoginEnabled: Bool?
    var createdFirstMove = false
    var rehearsedNotch = false

    var isComplete: Bool {
        completedAt != nil
            && (completedVersion ?? 0) >= Self.currentVersion
            && workspaceID != nil
            && storageMode != nil
            && calendarChoice != nil
            && launchAtLoginEnabled != nil
    }
}

/// Stores setup decisions locally. A completed version is explicit so a later
/// release can add a required privacy step without silently treating it as done.
@MainActor
final class FirstRunOnboardingStore: ObservableObject {
    private static let defaultsKey = "FoundersOffice.FirstRunOnboarding"

    @Published private var state: FirstRunOnboardingState
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()

    init(
        workspaceExistedBeforeLaunch: Bool,
        workspaceID: UUID,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults

        func resetState() -> FirstRunOnboardingState {
            var reset = FirstRunOnboardingState()
            reset.workspaceID = workspaceID
            reset.stepRawValue = workspaceExistedBeforeLaunch
                ? FirstRunStep.storage.rawValue
                : FirstRunStep.welcome.rawValue
            return reset
        }

        if let data = defaults.data(forKey: Self.defaultsKey) {
            guard let decoded = try? JSONDecoder().decode(FirstRunOnboardingState.self, from: data) else {
                // A damaged setup record must never fall through to the legacy
                // migration and silently opt a new workspace into cloud sync.
                state = resetState()
                persist()
                return
            }
            if decoded.schemaVersion < FirstRunOnboardingState.currentVersion {
                var upgrade = decoded
                upgrade.schemaVersion = FirstRunOnboardingState.currentVersion
                upgrade.completedAt = nil
                upgrade.completedVersion = nil
                upgrade.workspaceID = workspaceID
                // Earlier builds offered an iCloud choice before the shared
                // sync contract existed. Re-consent at the local-first screen;
                // never interpret that legacy value as permission to upload.
                upgrade.storageMode = nil
                upgrade.stepRawValue = FirstRunStep.storage.rawValue
                state = upgrade
                persist()
            } else if decoded.schemaVersion > FirstRunOnboardingState.currentVersion
                || decoded.workspaceID != workspaceID
                || (decoded.completedAt != nil && !decoded.isComplete) {
                // A downgrade, identity change, or incomplete completion marker
                // cannot reuse storage consent from another workspace/version.
                state = resetState()
                persist()
            } else {
                state = decoded
            }
            return
        }

        if workspaceExistedBeforeLaunch {
            // A build capability is not proof of consent. Existing beta
            // workspaces resume at the storage disclosure and remain local
            // until the person explicitly chooses iCloud.
            state = resetState()
            persist()
        } else {
            state = resetState()
            // Persist the in-progress marker before the user can quit. The task
            // store creates its first local file during the same launch, so the
            // next launch must not mistake that file for a legacy installation.
            persist()
        }
    }

    var isComplete: Bool { state.isComplete }
    var storageMode: FirstRunStorageMode? { state.storageMode }
    var workspaceID: UUID? { state.workspaceID }
    var preferredName: String? { state.preferredName }
    var didRehearseNotch: Bool { state.rehearsedNotch }
    var resumedStep: FirstRunStep {
        FirstRunStep(rawValue: state.stepRawValue) ?? .welcome
    }

    func recordName(_ name: String) {
        state.preferredName = name
        persist()
    }

    func recordStorageMode(_ mode: FirstRunStorageMode) {
        state.storageMode = mode
        persist()
    }

    func recordCalendarChoice(connected: Bool) {
        state.calendarChoice = connected ? .connected : .skipped
        persist()
    }

    func recordLaunchAtLogin(_ enabled: Bool) {
        state.launchAtLoginEnabled = enabled
        persist()
    }

    func recordFirstMove(created: Bool) {
        state.createdFirstMove = created
        persist()
    }

    func recordNotchRehearsal(completed: Bool) {
        state.rehearsedNotch = completed
        persist()
    }

    func recordStep(_ step: FirstRunStep) {
        state.stepRawValue = step.rawValue
        persist()
    }

    @discardableResult
    func complete() -> FirstRunStorageMode? {
        guard state.workspaceID != nil,
              let storageMode = state.storageMode,
              state.calendarChoice != nil,
              state.launchAtLoginEnabled != nil else { return nil }
        state.completedVersion = FirstRunOnboardingState.currentVersion
        state.completedAt = Date()
        state.stepRawValue = FirstRunStep.rehearsal.rawValue
        persist()
        return storageMode
    }

    private func persist() {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func persistedWorkspaceID(defaults: UserDefaults = .standard) -> UUID? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(FirstRunOnboardingState.self, from: data) else {
            return nil
        }
        return decoded.workspaceID
    }
}

private final class FirstRunPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FirstRunOnboardingWindowController {
    private let panel: FirstRunPanel

    init(
        stateStore: FirstRunOnboardingStore,
        taskStore: OpenLoopStore,
        personalization: PersonalizationStore,
        setLaunchAtLogin: @escaping (Bool) throws -> Bool,
        onComplete: @escaping (FirstRunStorageMode) -> Void
    ) {
        let model = FirstRunOnboardingModel(
            stateStore: stateStore,
            taskStore: taskStore,
            personalization: personalization,
            setLaunchAtLogin: setLaunchAtLogin,
            onComplete: onComplete
        )

        panel = FirstRunPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: FirstRunOnboardingView(model: model))
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = panel.frame
        let x = screen.frame.midX - frame.width / 2
        let topInset = max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
        let y = screen.frame.maxY - topInset - frame.height - 18
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel.orderOut(nil)
    }
}

@MainActor
private final class FirstRunOnboardingModel: ObservableObject {
    @Published var step: FirstRunStep
    @Published var nameDraft: String
    @Published var storageMode: FirstRunStorageMode?
    @Published var firstMoveDraft = ""
    @Published private(set) var isSavingFirstMove = false
    @Published var launchAtLoginEnabled: Bool
    @Published var launchError: String?
    @Published var moveError: String?
    @Published var didRehearseNotch: Bool

    let calendar = CalendarProvider()

    private let stateStore: FirstRunOnboardingStore
    private let taskStore: OpenLoopStore
    private let personalization: PersonalizationStore
    private let setLaunchAtLogin: (Bool) throws -> Bool
    private let onComplete: (FirstRunStorageMode) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        stateStore: FirstRunOnboardingStore,
        taskStore: OpenLoopStore,
        personalization: PersonalizationStore,
        setLaunchAtLogin: @escaping (Bool) throws -> Bool,
        onComplete: @escaping (FirstRunStorageMode) -> Void
    ) {
        self.stateStore = stateStore
        self.taskStore = taskStore
        self.personalization = personalization
        self.setLaunchAtLogin = setLaunchAtLogin
        self.onComplete = onComplete

        step = stateStore.resumedStep
        storageMode = stateStore.storageMode
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        didRehearseNotch = stateStore.didRehearseNotch

        let savedName = stateStore.preferredName ?? personalization.preferredName
        nameDraft = savedName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.suggestedPreferredName

        calendar.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var cleanName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func advanceFromWelcome() {
        guard !cleanName.isEmpty else { return }
        personalization.updatePreferredName(cleanName)
        stateStore.recordName(cleanName)
        go(to: .storage)
    }

    func chooseStorage(_ mode: FirstRunStorageMode) {
        storageMode = mode
        stateStore.recordStorageMode(mode)
    }

    func finishStorageStep() {
        // Onboarding is deliberately local-first. Product sign-in and an
        // explicit workspace disposition happen later in Account & Sync;
        // reaching this screen never authorizes an upload.
        chooseStorage(.localOnly)
        go(to: .calendar)
    }

    func connectCalendar() {
        calendar.connectOrOpenSettings()
    }

    func finishCalendarStep() {
        stateStore.recordCalendarChoice(connected: calendar.isAuthorized)
        go(to: .startup)
    }

    func setStartup(_ enabled: Bool) {
        launchError = nil
        do {
            let actualValue = try setLaunchAtLogin(enabled)
            launchAtLoginEnabled = actualValue
            stateStore.recordLaunchAtLogin(actualValue)
            if actualValue == enabled {
                go(to: .firstMove)
            } else {
                launchError = "macOS did not apply that setting. You can try again or continue without it."
            }
        } catch {
            launchError = error.localizedDescription
        }
    }

    func addFirstMove() {
        guard !isSavingFirstMove else { return }
        let title = firstMoveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        moveError = nil
        let previousIDs = Set(taskStore.items.map(\.id))
        taskStore.add(title: title, status: .next, priority: .p1, dueAt: nil)

        guard let added = taskStore.items.first(where: { !previousIDs.contains($0.id) }) else {
            moveError = "That Move could not be created. Try again or skip for now."
            return
        }

        isSavingFirstMove = true
        Task { [weak self] in
            guard let self else { return }
            let writesSaved = await taskStore.waitForPendingWrites()
            isSavingFirstMove = false
            guard writesSaved,
                  taskStore.session.snapshot.content.openLoops.items.contains(where: { $0.id == added.id }) else {
                taskStore.reload()
                moveError = "That Move was not saved. Your existing tasks were not changed. Try again or skip for now."
                return
            }

            stateStore.recordFirstMove(created: true)
            go(to: .rehearsal)
        }
    }

    func skipFirstMove() {
        taskStore.reload()
        stateStore.recordFirstMove(created: false)
        go(to: .rehearsal)
    }

    func markRehearsed() {
        guard !didRehearseNotch else { return }
        didRehearseNotch = true
        stateStore.recordNotchRehearsal(completed: true)
    }

    func finish(rehearsed: Bool) {
        stateStore.recordNotchRehearsal(completed: rehearsed)
        guard let mode = stateStore.complete() else { return }
        onComplete(mode)
    }

    func back() {
        guard let previous = FirstRunStep(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    private func go(to newStep: FirstRunStep) {
        step = newStep
        stateStore.recordStep(newStep)
    }

    private static var suggestedPreferredName: String {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullName.isEmpty else { return "" }
        if let components = PersonNameComponentsFormatter().personNameComponents(from: fullName),
           let givenName = components.givenName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !givenName.isEmpty {
            return givenName
        }
        return fullName.split(separator: " ").first.map(String.init) ?? fullName
    }
}

private struct FirstRunOnboardingView: View {
    @StateObject var model: FirstRunOnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField {
        case name
        case firstMove
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(32)
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .frame(width: 720, height: 500)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 38, y: 18)
        .preferredColorScheme(.dark)
        .onAppear { focusCurrentField() }
        .onChange(of: model.step) { _, _ in focusCurrentField() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: model.step.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.1), in: Circle())

            Text("Founder’s Office")
                .font(onboardingSystemFont(.secondary, weight: .semibold))

            Spacer()

            HStack(spacing: 7) {
                ForEach(FirstRunStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= model.step.rawValue ? Color.white : Color.white.opacity(0.18))
                        .frame(width: step == model.step ? 24 : 7, height: 7)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.step)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Setup step \(model.step.rawValue + 1) of \(FirstRunStep.allCases.count)")
        }
        .padding(.horizontal, 28)
        .frame(height: 68)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcomeStep
        case .storage: storageStep
        case .calendar: CalendarPermissionStep(model: model)
        case .startup: startupStep
        case .firstMove: firstMoveStep
        case .rehearsal: rehearsalStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingTitle("Welcome. What should we call you?")
            Text("Your name stays in your Founder’s Office workspace and shapes the greeting. You can change it later.")
                .font(onboardingSystemFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Preferred name", text: $model.nameDraft)
                .textFieldStyle(.plain)
                .font(onboardingSystemFont(.secondary, weight: .medium))
                .padding(.horizontal, 18)
                .frame(height: 58)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
                .focused($focusedField, equals: .name)
                .onSubmit(model.advanceFromWelcome)
                .accessibilityLabel("Preferred name")
        }
    }

    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("Start safely on this Mac")
            Text("Founder’s Office works without an account. Nothing is uploaded during setup.")
                .font(onboardingSystemFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.78))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "macbook")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.10), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local workspace")
                            .font(onboardingSystemFont(.secondary, weight: .semibold))
                        Text("Moves and personalization are stored in the transactional workspace on this Mac.")
                            .font(onboardingSystemFont(.tertiary))
                            .foregroundStyle(Color.white.opacity(0.76))
                    }
                }

                Divider().overlay(Color.white.opacity(0.10))

                Label {
                    Text("When you want the same workspace on another device, open Account & Sync and sign in with Google or Apple. You will review what happens to existing local data before any upload.")
                        .font(onboardingSystemFont(.tertiary, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .padding(20)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            }
        }
    }

    private var startupStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingTitle("Should it be ready when you log in?")
            Text(
                "Founder’s Office will only register as a login item after you press Enable. "
                    + "macOS keeps the final control in System Settings."
            )
                .font(onboardingSystemFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            Label(
                model.launchAtLoginEnabled ? "Launch at Login is on" : "Launch at Login is off",
                systemImage: model.launchAtLoginEnabled ? "checkmark.circle.fill" : "circle"
            )
            .font(onboardingSystemFont(.secondary, weight: .semibold))
            .foregroundStyle(model.launchAtLoginEnabled ? Color.green : Color.white)

            if let launchError = model.launchError {
                Label(launchError, systemImage: "exclamationmark.triangle.fill")
                    .font(onboardingSystemFont(.tertiary, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var firstMoveStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingTitle("What is your next Move?")
            Text("Add one concrete thing you want to move forward. If you are not ready, skip safely and add it from the notch later.")
                .font(onboardingSystemFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            TextField("For example: send the proposal", text: $model.firstMoveDraft)
                .textFieldStyle(.plain)
                .font(onboardingSystemFont(.secondary, weight: .medium))
                .padding(.horizontal, 18)
                .frame(height: 58)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
                .focused($focusedField, equals: .firstMove)
                .onSubmit(model.addFirstMove)

            if let moveError = model.moveError {
                Label(moveError, systemImage: "exclamationmark.triangle.fill")
                    .font(onboardingSystemFont(.tertiary, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rehearsalStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("One gesture. Then you are in.")
            Text("Move the pointer onto the notch below. It expands like the real one. Move away and it settles back.")
                .font(onboardingSystemFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.78))

            NotchRehearsal(didRehearse: model.didRehearseNotch) {
                model.markRehearsed()
            }
            .frame(maxWidth: .infinity)

            if model.didRehearseNotch {
                Label("You’ve got it", systemImage: "checkmark.circle.fill")
                    .font(onboardingSystemFont(.secondary, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome {
                Button("Back") { model.back() }
                    .buttonStyle(SecondaryOnboardingButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            switch model.step {
            case .welcome:
                Button("Continue", action: model.advanceFromWelcome)
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                    .disabled(model.cleanName.isEmpty)
                    .keyboardShortcut(.defaultAction)
            case .storage:
                Button("Continue on this Mac", action: model.finishStorageStep)
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .calendar:
                Button(model.calendar.isAuthorized ? "Continue" : "Not now", action: model.finishCalendarStep)
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .startup:
                if !model.launchAtLoginEnabled {
                    Button("Not now") { model.setStartup(false) }
                        .buttonStyle(SecondaryOnboardingButtonStyle())
                }
                Button(model.launchAtLoginEnabled ? "Continue" : "Enable Launch at Login") {
                    model.setStartup(true)
                }
                .buttonStyle(PrimaryOnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
            case .firstMove:
                Button("Skip for now", action: model.skipFirstMove)
                    .buttonStyle(SecondaryOnboardingButtonStyle())
                    .disabled(model.isSavingFirstMove)
                Button("Add Move", action: model.addFirstMove)
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                    .disabled(
                        model.isSavingFirstMove
                            || model.firstMoveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
            case .rehearsal:
                if !model.didRehearseNotch {
                    Button("Skip rehearsal") { model.finish(rehearsed: false) }
                        .buttonStyle(SecondaryOnboardingButtonStyle())
                }
                Button("Open Founder’s Office") { model.finish(rehearsed: model.didRehearseNotch) }
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
    }

    private func onboardingTitle(_ value: String) -> some View {
        Text(value)
            .font(onboardingDisplayFont(.primaryTitle))
            .foregroundStyle(Color.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func focusCurrentField() {
        DispatchQueue.main.async {
            switch model.step {
            case .welcome: focusedField = .name
            case .firstMove: focusedField = .firstMove
            default: focusedField = nil
            }
        }
    }
}

private struct CalendarPermissionStep: View {
    @ObservedObject var model: FirstRunOnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("See what matters next")
                .font(onboardingDisplayFont(.primaryTitle))
                .accessibilityAddTraits(.isHeader)

            Text(
                "Calendar access is optional. Founder’s Office reads upcoming event titles and times "
                    + "from the Calendar database on this Mac. It does not add, change, or upload events."
            )
                .font(onboardingSystemFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Image(systemName: model.calendar.isAuthorized ? "checkmark.circle.fill" : "calendar.badge.plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(model.calendar.isAuthorized ? Color.green : Color.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.calendar.isAuthorized ? "Calendar is connected" : "Calendar remains off until you allow it")
                        .font(onboardingSystemFont(.secondary, weight: .semibold))
                    Text(model.calendar.isAuthorized ? model.calendar.accountCountLabel : model.calendar.message)
                        .font(onboardingSystemFont(.tertiary))
                        .foregroundStyle(Color.white.opacity(0.75))
                }

                Spacer()

                if !model.calendar.isAuthorized {
                    Button(model.calendar.isDenied ? "Open Privacy Settings" : "Connect Calendar") {
                        model.connectCalendar()
                    }
                    .buttonStyle(SecondaryOnboardingButtonStyle())
                }
            }
            .padding(18)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct NotchRehearsal: View {
    let didRehearse: Bool
    let onRehearse: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: isHovered ? 25 : 15, style: .continuous)
                    .fill(Color.black)
                    .frame(width: isHovered ? 430 : 190, height: isHovered ? 126 : 34)
                    .overlay(alignment: .center) {
                        if isHovered {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.right.circle.fill")
                                    .font(.system(size: 24))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Your next Move is one glance away")
                                        .font(onboardingSystemFont(.secondary, weight: .semibold))
                                    Text("Move away to close it")
                                        .font(onboardingSystemFont(.tertiary))
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82),
                        value: isHovered
                    )
                    .onHover { hovering in
                        isHovered = hovering
                        if hovering { onRehearse() }
                    }
                    .accessibilityLabel("Notch rehearsal")
                    .accessibilityHint("Move the pointer here to rehearse opening Founder’s Office")

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 70, height: 7)
                    .offset(y: -1)
                    .allowsHitTesting(false)
            }
            .frame(height: 132, alignment: .top)

            if !didRehearse {
                Button("Rehearse with keyboard") {
                    isHovered = true
                    onRehearse()
                }
                .buttonStyle(.link)
                .accessibilityHint("Shows the same expansion without using a pointer")
            }
        }
    }
}

private struct PrimaryOnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(onboardingSystemFont(.secondary, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 20)
            .frame(minWidth: 112, minHeight: 42)
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SecondaryOnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(onboardingSystemFont(.secondary, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
