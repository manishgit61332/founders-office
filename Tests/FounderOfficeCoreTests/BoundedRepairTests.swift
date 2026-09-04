import Foundation
import Testing
@testable import FounderOfficeCore

struct BoundedRepairTests {
    @Test
    func successfulRepairPersistsBeforeAndAfterHealthEvidence() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        let health = RepairHealth()
        let ledger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let coordinator = BoundedRepairCoordinator(
            ledger: ledger,
            timeoutNanoseconds: 100_000_000,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = await coordinator.run(
            key: fixture.key,
            isHealthy: { await health.value },
            repair: { await health.markHealthy() }
        )

        #expect(result == .repaired(attempt: 1))
        let record = try #require(try await ledger.record(for: fixture.key))
        #expect(record.attemptCount == 1)
        #expect(record.state == .ready)
        #expect(record.beforeHealth == .unhealthy)
        #expect(record.afterHealth == .healthy)
        #expect(record.lastOutcome == .repaired)
        #expect(record.lastSucceededAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func timeoutReturnsPromptlyAndPersistsOnlyRedactedFailure() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        let marker = "PRIVATE MOVE /Users/founder@example.com secret-token"
        let ledger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let timeout = ControlledRepairTimeout()
        let repairGate = NonCooperativeRepairGate()
        let coordinator = BoundedRepairCoordinator(
            ledger: ledger,
            timeoutNanoseconds: 8_000_000,
            timeoutWait: { try await timeout.wait(nanoseconds: $0) }
        )

        let result = await coordinator.run(
            key: fixture.key,
            isHealthy: { false },
            repair: {
                _ = marker
                await timeout.repairDidStart()
                await repairGate.waitWhileIgnoringCancellation()
            }
        )

        #expect(await timeout.requestedNanoseconds == 8_000_000)
        #expect(result == .retryAvailable(attemptsUsed: 1, failure: .timedOut))
        let record = try #require(try await ledger.record(for: fixture.key))
        #expect(record.afterHealth == .unhealthy)
        #expect(record.lastOutcome == .timedOut)
        let text = try String(contentsOf: fixture.ledgerURL, encoding: .utf8)
        #expect(!text.contains(marker))
        #expect(!text.contains("/Users/"))
        #expect(!text.localizedCaseInsensitiveContains("token"))
        await repairGate.release()
    }

    @Test
    func timeoutCannotOverlapANonCooperativeAttemptWithTheSameKey() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        let gate = NonCooperativeRepairGate()
        let operationCount = RepairCounter()
        let ledger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let coordinator = BoundedRepairCoordinator(
            ledger: ledger,
            timeoutNanoseconds: 8_000_000
        )

        let first = await coordinator.run(
            key: fixture.key,
            isHealthy: { false },
            repair: {
                await operationCount.increment()
                await gate.waitWhileIgnoringCancellation()
            }
        )
        #expect(first == .retryAvailable(attemptsUsed: 1, failure: .timedOut))

        let blockedSecond = await coordinator.run(
            key: fixture.key,
            isHealthy: { false },
            repair: { await operationCount.increment() }
        )
        #expect(blockedSecond == first)
        #expect(await operationCount.value == 1)
        #expect(try await ledger.record(for: fixture.key)?.attemptCount == 1)

        await gate.release()
        for _ in 0..<100 where await gate.isWaiting {
            try await Task.sleep(for: .milliseconds(2))
        }
        try await Task.sleep(for: .milliseconds(10))

        let laterAttempt = await coordinator.run(
            key: fixture.key,
            isHealthy: { false },
            repair: {
                await operationCount.increment()
                throw RepairTestError.expected
            }
        )
        #expect(laterAttempt == .retryAvailable(attemptsUsed: 2, failure: .operationFailed))
        #expect(await operationCount.value == 2)
    }

    @Test
    func failedAttemptSurvivesCoordinatorAndLedgerRelaunch() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }

        let firstLedger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let first = BoundedRepairCoordinator(ledger: firstLedger)
        let firstResult = await first.run(
            key: fixture.key,
            isHealthy: { false },
            repair: { throw RepairTestError.expected }
        )
        #expect(firstResult == .retryAvailable(attemptsUsed: 1, failure: .operationFailed))

        let reopenedLedger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let reopened = BoundedRepairCoordinator(ledger: reopenedLedger)
        let secondResult = await reopened.run(
            key: fixture.key,
            isHealthy: { false },
            repair: { throw RepairTestError.expected }
        )

        #expect(secondResult == .retryAvailable(attemptsUsed: 2, failure: .operationFailed))
        let record = try #require(try await reopenedLedger.record(for: fixture.key))
        #expect(record.attemptCount == 2)
        #expect(record.state == .retryAvailable)
    }

    @Test
    func concurrentRequestsWithSameKeyShareOneOperation() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        let health = RepairHealth()
        let operationCount = RepairCounter()
        let ledger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let coordinator = BoundedRepairCoordinator(ledger: ledger)

        async let left = coordinator.run(
            key: fixture.key,
            isHealthy: { await health.value },
            repair: {
                await operationCount.increment()
                try await Task.sleep(for: .milliseconds(25))
                await health.markHealthy()
            }
        )
        async let right = coordinator.run(
            key: fixture.key,
            isHealthy: { await health.value },
            repair: {
                await operationCount.increment()
                try await Task.sleep(for: .milliseconds(25))
                await health.markHealthy()
            }
        )

        let results = await [left, right]
        #expect(results == [.repaired(attempt: 1), .repaired(attempt: 1)])
        #expect(await operationCount.value == 1)
    }

    @Test
    func threeFailuresStopAllFurtherOperationsAndRequireTheCustomer() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        let operationCount = RepairCounter()
        let ledger = BoundedRepairLedger(fileURL: fixture.ledgerURL)
        let coordinator = BoundedRepairCoordinator(ledger: ledger)

        for expectedAttempt in 1...3 {
            let result = await coordinator.run(
                key: fixture.key,
                isHealthy: { false },
                repair: {
                    await operationCount.increment()
                    throw RepairTestError.expected
                }
            )
            if expectedAttempt < 3 {
                #expect(result == .retryAvailable(
                    attemptsUsed: expectedAttempt,
                    failure: .operationFailed
                ))
            } else {
                #expect(result == .needsUser(
                    attemptsUsed: BoundedRepairCoordinator.maximumAttempts,
                    failure: .operationFailed
                ))
            }
        }

        let stopped = await coordinator.run(
            key: fixture.key,
            isHealthy: { false },
            repair: { await operationCount.increment() }
        )
        #expect(stopped == .needsUser(attemptsUsed: 3, failure: .operationFailed))
        #expect(await operationCount.value == 3)
        let record = try #require(try await ledger.record(for: fixture.key))
        #expect(record.state == .needsUser)
        #expect(record.attemptCount == 3)
    }

    @Test
    func corruptOrUnwritableLedgerFailsClosedWithoutRunningRepair() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.ledgerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a ledger".utf8).write(to: fixture.ledgerURL)
        let operationCount = RepairCounter()
        let coordinator = BoundedRepairCoordinator(
            ledger: BoundedRepairLedger(fileURL: fixture.ledgerURL)
        )

        let result = await coordinator.run(
            key: fixture.key,
            isHealthy: { false },
            repair: { await operationCount.increment() }
        )

        #expect(result == .needsUser(attemptsUsed: 0, failure: .ledgerUnavailable))
        #expect(await operationCount.value == 0)
    }
}

private enum RepairTestError: Error {
    case expected
}

private actor RepairHealth {
    private(set) var value = false

    func markHealthy() {
        value = true
    }
}

private actor RepairCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor NonCooperativeRepairGate {
    private(set) var isWaiting = true

    func waitWhileIgnoringCancellation() async {
        while isWaiting {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release() {
        isWaiting = false
    }
}

private actor ControlledRepairTimeout {
    private(set) var requestedNanoseconds: UInt64?
    private var repairStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(nanoseconds: UInt64) async throws {
        requestedNanoseconds = nanoseconds
        guard !repairStarted else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func repairDidStart() {
        repairStarted = true
        continuation?.resume()
        continuation = nil
    }
}

private struct RepairFixture {
    let rootURL: URL
    let ledgerURL: URL
    let key = BoundedRepairKey(kind: .generatedProjection, generation: 42)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "founder-office-bounded-repair-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        ledgerURL = rootURL
            .appendingPathComponent("RuntimeHealth", isDirectory: true)
            .appendingPathComponent("repair-ledger-v1.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
