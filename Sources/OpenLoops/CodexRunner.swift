import AppKit
import Foundation
import FounderOfficeCore

#if !FOUNDER_OFFICE_DISTRIBUTION
enum CodexTaskAction {
    case execute
    case prepare

    var label: String {
        switch self {
        case .execute: return "Run with Codex"
        case .prepare: return "Prepare with Codex"
        }
    }

    var instruction: String {
        switch self {
        case .execute:
            return "Complete as much of this task as can be safely completed through research, writing, analysis, code, and local file work."
        case .prepare:
            return "This task contains a human or external action. Prepare every useful local artifact, draft, decision, checklist, or research input, but leave the final human action to the user."
        }
    }
}

enum CodexRunState {
    case idle
    case running(title: String)
    case finished(title: String, summaryURL: URL)
    case failed(title: String, message: String)
}

@MainActor
final class CodexRunner: ObservableObject {
    @Published private(set) var state: CodexRunState = .idle
    @Published private(set) var lastSuccessfulRunAt: Date?

    let founderOfficeURL: URL
    private var process: Process?

    init(founderOfficeURL: URL) {
        self.founderOfficeURL = founderOfficeURL
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isAvailable: Bool {
        true
    }

    func action(for item: OpenLoop) -> CodexTaskAction {
        let text = "\(item.title) \(item.details)".lowercased()
        let externalActionWords = [
            "book", "call", "confirm", "deliver", "film", "publish", "reconnect",
            "record", "restore", "schedule", "send", "shoot", "upload"
        ]
        return externalActionWords.contains(where: text.contains) ? .prepare : .execute
    }

    func run(_ item: OpenLoop) {
        guard !isRunning else { return }

        let action = action(for: item)
        let timestamp = Self.folderDateFormatter.string(from: Date())
        let runName = "\(item.id.uuidString.lowercased().prefix(8))-\(timestamp)"
        let runURL = founderOfficeURL
            .appendingPathComponent("Codex Runs", isDirectory: true)
            .appendingPathComponent(runName, isDirectory: true)
        let summaryURL = runURL.appendingPathComponent("summary.md")
        let eventsURL = runURL.appendingPathComponent("events.jsonl")
        let logURL = runURL.appendingPathComponent("run.log")
        let promptURL = runURL.appendingPathComponent("prompt.md")

        do {
            try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
            let prompt = prompt(for: item, action: action, runURL: runURL)
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let eventsHandle = try FileHandle(forWritingTo: eventsURL)
            let logHandle = try FileHandle(forWritingTo: logURL)

            let process = Process()
            let invocation = Self.codexInvocation
            process.executableURL = invocation.executableURL
            process.arguments = invocation.argumentPrefix + [
                "exec",
                "-m", "gpt-5.5",
                "-C", founderOfficeURL.path,
                "--sandbox", "workspace-write",
                "--skip-git-repo-check",
                "--ephemeral",
                "--color", "never",
                "--json",
                "--output-last-message", summaryURL.path,
                prompt
            ]
            process.standardOutput = eventsHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] completedProcess in
                try? eventsHandle.close()
                try? logHandle.close()

                Task { @MainActor in
                    guard let self else { return }
                    self.process = nil

                    if completedProcess.terminationStatus == 0,
                       FileManager.default.fileExists(atPath: summaryURL.path) {
                        self.lastSuccessfulRunAt = Date()
                        self.state = .finished(title: item.title, summaryURL: summaryURL)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    } else {
                        let fallback = "Codex stopped before finishing"
                        let message = Self.lastUsefulLine(in: logURL) ?? fallback
                        self.state = .failed(title: item.title, message: message)
                    }
                }
            }

            try process.run()
            self.process = process
            state = .running(title: item.title)
        } catch {
            process = nil
            state = .failed(title: item.title, message: "Couldn’t start Codex")
            AppDiagnostics.failure(.codexProcessStart, category: .automation, error: error)
        }
    }

    func prepareForTermination() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    private func prompt(for item: OpenLoop, action: CodexTaskAction, runURL: URL) -> String {
        """
        Work on this Founder's Office move:

        Title: \(item.title)
        Details: \(item.details.isEmpty ? "No extra details were provided." : item.details)
        Priority: \(item.priority.rawValue)
        Move ID: \(item.id.uuidString.lowercased())

        \(action.instruction)

        Rules:
        - Read AGENTS.md and OPEN_LOOPS_CONTEXT.md before acting when those files exist.
        - Take concrete action in the Founder Office workspace; do not only propose a plan.
        - Save the durable result inside this run folder: \(runURL.path)
        - You may read existing workspace material and create or update task-specific deliverables.
        - Do not send messages, publish content, schedule calls, make purchases, use private credentials, or make other irreversible external changes.
        - Do not delete existing files.
        - Do not edit founders-office.sqlite3, generated workspace projections, or mark the task done. The user will review the result first.
        - Finish with a concise summary of what you completed and the exact files to review.
        """
    }

    private static var codexInvocation: (executableURL: URL, argumentPrefix: [String]) {
        let knownPaths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        if let path = knownPaths.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return (URL(fileURLWithPath: path), [])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["codex"])
    }

    private static func lastUsefulLine(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
#endif
