import AppKit
import FounderOfficeCore

@MainActor
final class FounderOfficeUpdateController {
    private enum PreferenceKey {
        static let installationID = "FounderOfficeUpdateInstallationID"

        static func lastAutomaticCheck(namespace: String) -> String {
            "FounderOfficeLastAutomaticUpdateCheck.\(namespace)"
        }

        static func acceptedFeedSequence(namespace: String) -> String {
            "FounderOfficeAcceptedUpdateFeedSequence.\(namespace)"
        }

        static func acceptedFeedPayloadSHA256(namespace: String) -> String {
            "FounderOfficeAcceptedUpdateFeedPayloadSHA256.\(namespace)"
        }
    }

    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private weak var notchController: NotchWindowController?
    private let configurationResult: Result<UpdateChannelConfiguration, UpdateChannelError>
    private let httpClient: UpdateChannelHTTPClient
    private let defaults: UserDefaults
    private let bundle: Bundle
    private var checkTask: Task<Void, Never>?

    init(
        notchController: NotchWindowController,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        httpClient: UpdateChannelHTTPClient = UpdateChannelHTTPClient(),
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) {
        self.notchController = notchController
        configurationResult = UpdateChannelConfiguration.load(infoDictionary: infoDictionary)
        self.httpClient = httpClient
        self.defaults = defaults
        self.bundle = bundle
    }

    func startAutomaticCheckAfterRuntimeReady() {
        guard case let .success(configuration) = configurationResult,
              checkTask == nil else { return }

        let now = Date()
        let checkKey = PreferenceKey.lastAutomaticCheck(
            namespace: configuration.persistenceNamespace
        )
        let lastCheck = defaults.object(forKey: checkKey) as? Date
        guard UpdateCheckSchedule.shouldAttempt(
            lastAttempt: lastCheck,
            now: now,
            minimumInterval: Self.automaticCheckInterval
        ) else {
            return
        }

        // Record the attempt before network work begins. Offline Macs therefore
        // retry at most once a day instead of polling on every app activation.
        defaults.set(now, forKey: checkKey)
        runCheck(mode: .automatic)
    }

    func checkManually() {
        guard checkTask == nil else { return }
        runCheck(mode: .manual)
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
    }

    private func runCheck(mode: UpdateCheckMode) {
        guard checkTask == nil else { return }
        let configurationResult = configurationResult
        let httpClient = httpClient
        let installationID = resolvedInstallationID()
        let currentBuild = resolvedCurrentBuild()
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion

        checkTask = Task { [weak self] in
            defer { self?.checkTask = nil }
            guard let self else { return }

            let configuration: UpdateChannelConfiguration
            switch configurationResult {
            case let .success(value):
                configuration = value
            case let .failure(error):
                if mode == .manual {
                    presentFailure(error)
                }
                return
            }

            do {
                let envelope = try await httpClient.fetchEnvelope(configuration: configuration)
                try Task.checkCancellation()
                let verified = try envelope.verifiedUpdate(configuration: configuration)
                try acceptAgainstReplay(verified, configuration: configuration)
                let manifest = verified.manifest
                let availability = UpdateChannelEvaluator.evaluate(
                    manifest: manifest,
                    currentBuild: currentBuild,
                    currentSystemVersion: systemVersion,
                    installationID: installationID,
                    mode: mode
                )
                AppDiagnostics.event(
                    .updateCheck,
                    category: .update,
                    outcome: .success
                )
                handle(availability, mode: mode)
            } catch is CancellationError {
                return
            } catch {
                AppDiagnostics.failure(.updateCheck, category: .update, error: error)
                if mode == .manual {
                    presentFailure(error)
                }
            }
        }
    }

    private func acceptAgainstReplay(
        _ verified: VerifiedUpdateManifest,
        configuration: UpdateChannelConfiguration
    ) throws {
        let sequenceKey = PreferenceKey.acceptedFeedSequence(
            namespace: configuration.persistenceNamespace
        )
        let digestKey = PreferenceKey.acceptedFeedPayloadSHA256(
            namespace: configuration.persistenceNamespace
        )
        let storedSequence: Int64?
        if defaults.object(forKey: sequenceKey) == nil {
            storedSequence = nil
        } else {
            storedSequence = (defaults.object(forKey: sequenceKey) as? NSNumber)?.int64Value
        }
        let storedDigest = defaults.string(forKey: digestKey)
        switch UpdateFeedReplayGuard.evaluate(
            candidateSequence: verified.manifest.sequence,
            candidatePayloadSHA256: verified.payloadSHA256,
            acceptedSequence: storedSequence,
            acceptedPayloadSHA256: storedDigest
        ) {
        case .acceptSame:
            return
        case .acceptNew:
            defaults.set(
                verified.manifest.sequence,
                forKey: sequenceKey
            )
            defaults.set(
                verified.payloadSHA256,
                forKey: digestKey
            )
        case .reject:
            throw UpdateChannelError.invalidManifest
        }
    }

    private func handle(_ availability: UpdateAvailability, mode: UpdateCheckMode) {
        switch availability {
        case let .available(release):
            presentAvailable(release)
        case .current:
            if mode == .manual {
                presentInformational(
                    title: "Founder’s Office is up to date",
                    detail: "This Mac already has the latest available build."
                )
            }
        case .paused:
            if mode == .manual {
                presentInformational(
                    title: "This update is paused",
                    detail: "No download was opened. Check again after the release review is complete."
                )
            }
        case .notYetEligible:
            if mode == .manual {
                presentInformational(
                    title: "Founder’s Office is up to date",
                    detail: "No newer build is currently available for this Mac."
                )
            }
        case let .requiresNewerSystem(version):
            if mode == .manual {
                presentInformational(
                    title: "A newer macOS version is required",
                    detail: "The available build requires macOS \(version) or later."
                )
            }
        }
    }

    private func presentAvailable(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Founder’s Office \(release.version) is available"
        alert.informativeText = "Build \(release.build) is ready on the verified Founder’s Office download site. The app will not install anything automatically."
        alert.addButton(withTitle: "Open Download")
        alert.addButton(withTitle: "Later")

        guard present(alert) == .alertFirstButtonReturn else { return }
        guard NSWorkspace.shared.open(release.artifactURL) else {
            AppDiagnostics.failure(
                .updateDownloadOpen,
                category: .update,
                domain: "FounderOffice.Update",
                code: 1
            )
            presentInformational(
                title: "Couldn’t open the download",
                detail: "No download was started. Please try again later."
            )
            return
        }
        AppDiagnostics.event(
            .updateDownloadOpen,
            category: .update,
            outcome: .success
        )
    }

    private func presentFailure(_ error: Error) {
        let detail: String
        if let channelError = error as? UpdateChannelError {
            detail = channelError.localizedDescription
        } else {
            detail = "Founder’s Office could not verify the update channel. No download was opened."
        }
        presentInformational(title: "Couldn’t check for updates", detail: detail)
    }

    private func presentInformational(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        _ = present(alert)
    }

    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if let notchController {
            return notchController.runSystemAlert(alert, reason: "update-channel")
        }
        return alert.runModal()
    }

    private func resolvedInstallationID() -> UUID {
        if let text = defaults.string(forKey: PreferenceKey.installationID),
           let existing = UUID(uuidString: text) {
            return existing
        }
        let created = UUID()
        defaults.set(created.uuidString.lowercased(), forKey: PreferenceKey.installationID)
        return created
    }

    private func resolvedCurrentBuild() -> Int {
        let text = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return max(Int(text ?? "") ?? 0, 0)
    }
}
