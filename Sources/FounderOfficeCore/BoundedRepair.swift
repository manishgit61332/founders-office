import Foundation

/// Derived state that Founder’s Office may rebuild without changing customer
/// content, credentials, permissions, installed code, or task state.
public enum BoundedRepairKind: String, CaseIterable, Codable, Hashable, Sendable {
    case generatedProjection = "generated_projection"
    case disposableCache = "disposable_cache"
    case calendarObserver = "calendar_observer"
    case optionalNetwork = "optional_network"
}

/// A deterministic, content-free idempotency key. `generation` is a local
/// structural revision, never a workspace, account, path, or entity ID.
public struct BoundedRepairKey: Codable, Hashable, Sendable {
    public var kind: BoundedRepairKind
    public var generation: UInt64

    public init(kind: BoundedRepairKind, generation: UInt64) {
        self.kind = kind
        self.generation = generation
    }

    public var stableIdentifier: String {
        "\(kind.rawValue):\(generation)"
    }
}

public enum BoundedRepairHealth: String, Codable, Hashable, Sendable {
    case unknown
    case healthy
    case unhealthy
}

public enum BoundedRepairOutcome: String, Codable, Hashable, Sendable {
    case started
    case alreadyHealthy = "already_healthy"
    case repaired
    case timedOut = "timed_out"
    case operationFailed = "operation_failed"
    case remainedUnhealthy = "remained_unhealthy"
    case ledgerUnavailable = "ledger_unavailable"
}

public enum BoundedRepairRecordState: String, Codable, Hashable, Sendable {
    case running
    case ready
    case retryAvailable = "retry_available"
    case needsUser = "needs_user"
}

/// The complete durable repair evidence. Every field is structural and
/// bounded. There is intentionally no string slot for an error, path, title,
/// account, prompt, or other customer content.
public struct BoundedRepairRecord: Codable, Equatable, Sendable {
    public var key: BoundedRepairKey
    public var attemptCount: Int
    public var state: BoundedRepairRecordState
    public var beforeHealth: BoundedRepairHealth
    public var afterHealth: BoundedRepairHealth
    public var lastOutcome: BoundedRepairOutcome
    public var lastStartedAt: Date?
    public var lastFinishedAt: Date?
    public var lastSucceededAt: Date?

    public init(
        key: BoundedRepairKey,
        attemptCount: Int = 0,
        state: BoundedRepairRecordState = .retryAvailable,
        beforeHealth: BoundedRepairHealth = .unknown,
        afterHealth: BoundedRepairHealth = .unknown,
        lastOutcome: BoundedRepairOutcome = .remainedUnhealthy,
        lastStartedAt: Date? = nil,
        lastFinishedAt: Date? = nil,
        lastSucceededAt: Date? = nil
    ) {
        self.key = key
        self.attemptCount = min(max(attemptCount, 0), BoundedRepairCoordinator.maximumAttempts)
        self.state = state
        self.beforeHealth = beforeHealth
        self.afterHealth = afterHealth
        self.lastOutcome = lastOutcome
        self.lastStartedAt = lastStartedAt
        self.lastFinishedAt = lastFinishedAt
        self.lastSucceededAt = lastSucceededAt
    }
}

public enum BoundedRepairFailure: String, Codable, Equatable, Sendable {
    case timedOut = "timed_out"
    case operationFailed = "operation_failed"
    case remainedUnhealthy = "remained_unhealthy"
    case ledgerUnavailable = "ledger_unavailable"
}

public enum BoundedRepairResult: Equatable, Sendable {
    case alreadyHealthy
    case repaired(attempt: Int)
    case retryAvailable(attemptsUsed: Int, failure: BoundedRepairFailure)
    case needsUser(attemptsUsed: Int, failure: BoundedRepairFailure)

    public var customerState: BoundedRepairCustomerState {
        switch self {
        case .alreadyHealthy, .repaired:
            return .ready
        case let .retryAvailable(attemptsUsed, _):
            return .retryAvailable(attemptsUsed: attemptsUsed)
        case let .needsUser(attemptsUsed, _):
            return .needsUser(attemptsUsed: attemptsUsed)
        }
    }
}

/// The only repair state exposed to product UI. Details remain fixed copy in
/// the client rather than coming from an error or ledger payload.
public enum BoundedRepairCustomerState: Equatable, Sendable {
    case ready
    case retryAvailable(attemptsUsed: Int)
    case needsUser(attemptsUsed: Int)
}

public enum BoundedRepairLedgerError: Error, Equatable, Sendable {
    case unavailable
    case invalidDocument
}

/// A small, separate, durable ledger for derived-state repairs. It is never
/// stored in the canonical workspace database and never accepts customer text.
public actor BoundedRepairLedger {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var records: [BoundedRepairRecord]
    }

    private static let maximumByteCount = 256 * 1_024
    private static let maximumRecordCount = 64

    private let fileURL: URL
    private var cachedDocument: Document?
    private var loadFailed = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(for key: BoundedRepairKey) throws -> BoundedRepairRecord? {
        try document().records.first { $0.key == key }
    }

    fileprivate func observeHealthy(
        key: BoundedRepairKey,
        at date: Date,
        createIfMissing: Bool = true
    ) throws {
        let existing = try record(for: key)
        guard createIfMissing || existing != nil else { return }
        var value = existing ?? BoundedRepairRecord(key: key)
        value.attemptCount = 0
        value.state = .ready
        value.beforeHealth = .healthy
        value.afterHealth = .healthy
        value.lastOutcome = .alreadyHealthy
        value.lastFinishedAt = date
        value.lastSucceededAt = date
        try upsert(value)
    }

    fileprivate func beginAttempt(
        key: BoundedRepairKey,
        at date: Date
    ) throws -> BoundedRepairRecord? {
        var value = try record(for: key) ?? BoundedRepairRecord(key: key)
        guard value.attemptCount < BoundedRepairCoordinator.maximumAttempts,
              value.state != .needsUser else {
            return nil
        }

        value.attemptCount += 1
        value.state = .running
        value.beforeHealth = .unhealthy
        value.afterHealth = .unknown
        value.lastOutcome = .started
        value.lastStartedAt = date
        value.lastFinishedAt = nil
        try upsert(value)
        return value
    }

    fileprivate func finishAttempt(
        key: BoundedRepairKey,
        afterHealth: BoundedRepairHealth,
        outcome: BoundedRepairOutcome,
        at date: Date
    ) throws -> BoundedRepairRecord {
        guard var value = try record(for: key), value.state == .running else {
            throw BoundedRepairLedgerError.invalidDocument
        }

        value.afterHealth = afterHealth
        value.lastOutcome = outcome
        value.lastFinishedAt = date
        if afterHealth == .healthy {
            value.state = .ready
            value.lastSucceededAt = date
        } else if value.attemptCount >= BoundedRepairCoordinator.maximumAttempts {
            value.state = .needsUser
        } else {
            value.state = .retryAvailable
        }
        try upsert(value)
        return value
    }

    fileprivate func markNeedsUser(
        key: BoundedRepairKey,
        at date: Date
    ) throws -> BoundedRepairRecord {
        var value = try record(for: key) ?? BoundedRepairRecord(key: key)
        value.attemptCount = min(
            max(value.attemptCount, BoundedRepairCoordinator.maximumAttempts),
            BoundedRepairCoordinator.maximumAttempts
        )
        value.state = .needsUser
        value.beforeHealth = .unhealthy
        value.afterHealth = .unhealthy
        if value.lastOutcome == .started || value.lastOutcome == .alreadyHealthy {
            value.lastOutcome = .remainedUnhealthy
        }
        value.lastFinishedAt = date
        try upsert(value)
        return value
    }

    private func document() throws -> Document {
        if let cachedDocument { return cachedDocument }
        guard !loadFailed else { throw BoundedRepairLedgerError.invalidDocument }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let fresh = Document(schemaVersion: Document.currentSchemaVersion, records: [])
            cachedDocument = fresh
            return fresh
        }

        do {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount <= Self.maximumByteCount else {
                throw BoundedRepairLedgerError.invalidDocument
            }

            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decoded = try decoder.decode(Document.self, from: data)
            try Self.validate(decoded)
            cachedDocument = decoded
            return decoded
        } catch let error as BoundedRepairLedgerError {
            loadFailed = true
            throw error
        } catch {
            loadFailed = true
            throw BoundedRepairLedgerError.invalidDocument
        }
    }

    private func upsert(_ record: BoundedRepairRecord) throws {
        var value = try document()
        value.records.removeAll { $0.key == record.key }
        value.records.append(record)
        value.records.sort { left, right in
            let leftDate = left.lastFinishedAt ?? left.lastStartedAt ?? .distantPast
            let rightDate = right.lastFinishedAt ?? right.lastStartedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.key.stableIdentifier < right.key.stableIdentifier
        }
        if value.records.count > Self.maximumRecordCount {
            value.records.removeLast(value.records.count - Self.maximumRecordCount)
        }
        try persist(value)
        cachedDocument = value
    }

    private func persist(_ document: Document) throws {
        do {
            let fileManager = FileManager.default
            let parentURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: fileURL.path) {
                let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw BoundedRepairLedgerError.unavailable
                }
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumByteCount else {
                throw BoundedRepairLedgerError.unavailable
            }
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as BoundedRepairLedgerError {
            throw error
        } catch {
            throw BoundedRepairLedgerError.unavailable
        }
    }

    private static func validate(_ document: Document) throws {
        guard document.schemaVersion == Document.currentSchemaVersion,
              document.records.count <= maximumRecordCount,
              Set(document.records.map(\.key)).count == document.records.count else {
            throw BoundedRepairLedgerError.invalidDocument
        }

        for record in document.records {
            guard (0...BoundedRepairCoordinator.maximumAttempts).contains(record.attemptCount) else {
                throw BoundedRepairLedgerError.invalidDocument
            }
            if record.state == .needsUser,
               record.attemptCount != BoundedRepairCoordinator.maximumAttempts {
                throw BoundedRepairLedgerError.invalidDocument
            }
        }
    }
}

/// Runs at most one attempt per trigger and at most three attempts for a
/// stable key across process launches. Concurrent requests for the same key
/// share one in-flight task.
public actor BoundedRepairCoordinator {
    public static let maximumAttempts = 3

    public typealias HealthCheck = @Sendable () async -> Bool
    public typealias RepairOperation = @Sendable () async throws -> Void

    private let ledger: BoundedRepairLedger
    private let timeoutNanoseconds: UInt64
    private let clock: @Sendable () -> Date
    private let timeoutWait: @Sendable (UInt64) async throws -> Void
    private var inFlight: [BoundedRepairKey: Task<RepairExecution, Never>] = [:]
    private var lingering: [BoundedRepairKey: LingeringOperation] = [:]

    public init(
        ledger: BoundedRepairLedger,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ledger = ledger
        self.timeoutNanoseconds = min(max(timeoutNanoseconds, 1_000_000), 60_000_000_000)
        self.clock = clock
        timeoutWait = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        ledger: BoundedRepairLedger,
        timeoutNanoseconds: UInt64,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeoutWait: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.ledger = ledger
        self.timeoutNanoseconds = min(max(timeoutNanoseconds, 1_000_000), 60_000_000_000)
        self.clock = clock
        self.timeoutWait = timeoutWait
    }

    public func run(
        key: BoundedRepairKey,
        isHealthy: @escaping HealthCheck,
        repair: @escaping RepairOperation
    ) async -> BoundedRepairResult {
        // A timeout is a deadline for the caller, not proof that a
        // non-cooperative operation stopped. Never overlap a second repair for
        // the same key while that cancelled task is still unwinding.
        if let lingering = lingering[key] {
            return lingering.result
        }
        if let task = inFlight[key] {
            return await task.value.result
        }

        let ledger = self.ledger
        let timeoutNanoseconds = self.timeoutNanoseconds
        let clock = self.clock
        let timeoutWait = self.timeoutWait
        let task = Task {
            await Self.execute(
                key: key,
                ledger: ledger,
                timeoutNanoseconds: timeoutNanoseconds,
                clock: clock,
                timeoutWait: timeoutWait,
                isHealthy: isHealthy,
                repair: repair
            )
        }
        inFlight[key] = task
        let execution = await task.value
        inFlight.removeValue(forKey: key)
        if let operationTask = execution.lingeringTask {
            let token = UUID()
            lingering[key] = LingeringOperation(
                token: token,
                task: operationTask,
                result: execution.result
            )
            Task { [weak self] in
                await operationTask.value
                await self?.clearLingeringOperation(key: key, token: token)
            }
        }
        return execution.result
    }

    /// Clears a prior failed-attempt budget only when a record for this key
    /// already exists. Routine healthy projection writes therefore do not
    /// create repair-ledger traffic.
    public func confirmHealthy(key: BoundedRepairKey) async {
        try? await ledger.observeHealthy(
            key: key,
            at: clock(),
            createIfMissing: false
        )
    }

    private static func execute(
        key: BoundedRepairKey,
        ledger: BoundedRepairLedger,
        timeoutNanoseconds: UInt64,
        clock: @escaping @Sendable () -> Date,
        timeoutWait: @escaping @Sendable (UInt64) async throws -> Void,
        isHealthy: @escaping HealthCheck,
        repair: @escaping RepairOperation
    ) async -> RepairExecution {
        if await isHealthy() {
            do {
                try await ledger.observeHealthy(key: key, at: clock())
                return RepairExecution(result: .alreadyHealthy)
            } catch {
                return RepairExecution(
                    result: .needsUser(attemptsUsed: 0, failure: .ledgerUnavailable)
                )
            }
        }

        let attempt: BoundedRepairRecord
        do {
            guard let started = try await ledger.beginAttempt(key: key, at: clock()) else {
                let stopped = try await ledger.markNeedsUser(key: key, at: clock())
                return RepairExecution(
                    result: .needsUser(
                        attemptsUsed: stopped.attemptCount,
                        failure: Self.failure(from: stopped.lastOutcome)
                    )
                )
            }
            attempt = started
        } catch {
            return RepairExecution(
                result: .needsUser(attemptsUsed: 0, failure: .ledgerUnavailable)
            )
        }

        let timedExecution = await performWithTimeout(
            nanoseconds: timeoutNanoseconds,
            timeoutWait: timeoutWait,
            operation: repair
        )
        let afterIsHealthy = await isHealthy()
        let outcome: BoundedRepairOutcome
        if afterIsHealthy {
            outcome = .repaired
        } else {
            switch timedExecution.completion {
            case .completed:
                outcome = .remainedUnhealthy
            case .failed:
                outcome = .operationFailed
            case .timedOut:
                outcome = .timedOut
            }
        }

        do {
            let finished = try await ledger.finishAttempt(
                key: key,
                afterHealth: afterIsHealthy ? .healthy : .unhealthy,
                outcome: outcome,
                at: clock()
            )
            if afterIsHealthy {
                return RepairExecution(
                    result: .repaired(attempt: attempt.attemptCount),
                    lingeringTask: timedExecution.lingeringTask
                )
            }
            let failure = Self.failure(from: outcome)
            if finished.state == .needsUser {
                return RepairExecution(
                    result: .needsUser(
                        attemptsUsed: finished.attemptCount,
                        failure: failure
                    ),
                    lingeringTask: timedExecution.lingeringTask
                )
            }
            return RepairExecution(
                result: .retryAvailable(
                    attemptsUsed: finished.attemptCount,
                    failure: failure
                ),
                lingeringTask: timedExecution.lingeringTask
            )
        } catch {
            return RepairExecution(
                result: .needsUser(
                    attemptsUsed: attempt.attemptCount,
                    failure: .ledgerUnavailable
                ),
                lingeringTask: timedExecution.lingeringTask
            )
        }
    }

    private func clearLingeringOperation(key: BoundedRepairKey, token: UUID) {
        guard lingering[key]?.token == token else { return }
        lingering.removeValue(forKey: key)
    }

    private static func failure(from outcome: BoundedRepairOutcome) -> BoundedRepairFailure {
        switch outcome {
        case .timedOut:
            return .timedOut
        case .operationFailed:
            return .operationFailed
        case .ledgerUnavailable:
            return .ledgerUnavailable
        case .started, .alreadyHealthy, .repaired, .remainedUnhealthy:
            return .remainedUnhealthy
        }
    }

    private enum AttemptCompletion: Equatable, Sendable {
        case completed
        case failed
        case timedOut
    }

    private struct TimedExecution: Sendable {
        var completion: AttemptCompletion
        var lingeringTask: Task<Void, Never>?
    }

    private struct RepairExecution: Sendable {
        var result: BoundedRepairResult
        var lingeringTask: Task<Void, Never>?

        init(
            result: BoundedRepairResult,
            lingeringTask: Task<Void, Never>? = nil
        ) {
            self.result = result
            self.lingeringTask = lingeringTask
        }
    }

    private struct LingeringOperation {
        var token: UUID
        var task: Task<Void, Never>
        var result: BoundedRepairResult
    }

    private static func performWithTimeout(
        nanoseconds: UInt64,
        timeoutWait: @escaping @Sendable (UInt64) async throws -> Void,
        operation: @escaping RepairOperation
    ) async -> TimedExecution {
        let race = RepairAttemptRace()
        let operationTask = Task {
            do {
                try await operation()
                await race.resolve(.completed)
            } catch {
                await race.resolve(.failed)
            }
        }
        let timeoutTask = Task {
            do {
                try await timeoutWait(nanoseconds)
                await race.resolve(.timedOut)
            } catch {
                // The winning operation cancels this timer.
            }
        }

        let result = await race.wait()
        operationTask.cancel()
        timeoutTask.cancel()
        return TimedExecution(
            completion: result,
            lingeringTask: result == .timedOut ? operationTask : nil
        )
    }

    private actor RepairAttemptRace {
        private var result: AttemptCompletion?
        private var continuation: CheckedContinuation<AttemptCompletion, Never>?

        func wait() async -> AttemptCompletion {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                }
            }
        }

        func resolve(_ value: AttemptCompletion) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
