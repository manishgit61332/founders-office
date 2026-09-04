import Foundation
import Testing
@testable import OpenLoops

struct CrashLoopSafeModeTests {
    @Test
    func cleanTerminationBeforeReadyDoesNotCreateAFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        #expect(first.beginLaunch().consecutivePreReadyFailures == 0)
        first.markCleanTermination()

        let next = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        let disposition = next.beginLaunch()
        #expect(disposition.consecutivePreReadyFailures == 0)
        #expect(!disposition.isSafeMode)
    }

    @Test
    func cleanTerminationPreservesEarlierFailureEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let failedLaunch = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        _ = failedLaunch.beginLaunch()

        let cleanLaunch = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        #expect(cleanLaunch.beginLaunch().consecutivePreReadyFailures == 1)
        cleanLaunch.markCleanTermination()

        let next = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        let disposition = next.beginLaunch()
        #expect(disposition.consecutivePreReadyFailures == 1)
        #expect(!disposition.isSafeMode)
    }

    @Test
    func repeatedUncleanLaunchesStillLatchSafeMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let expectedFailureCounts = [0, 1, 2, 3]
        for (index, expectedCount) in expectedFailureCounts.enumerated() {
            let marker = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
            let disposition = marker.beginLaunch()
            #expect(disposition.consecutivePreReadyFailures == expectedCount)
            #expect(disposition.isSafeMode == (index == expectedFailureCounts.count - 1))
        }
    }

    @Test
    func cleanTerminationDoesNotClearLatchedSafeMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        var safeMarker: CrashLoopSafeModeMarker?
        for _ in 0 ... 3 {
            safeMarker = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
            _ = safeMarker?.beginLaunch()
        }
        #expect(safeMarker?.disposition.isSafeMode == true)

        safeMarker?.markCleanTermination()
        safeMarker?.markCleanTermination()

        let stillSafe = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        #expect(stillSafe.beginLaunch().isSafeMode)
        stillSafe.prepareExplicitRetry()

        let retried = CrashLoopSafeModeMarker(defaults: fixture.defaults, bundle: .main)
        let disposition = retried.beginLaunch()
        #expect(!disposition.isSafeMode)
        #expect(disposition.consecutivePreReadyFailures == 0)
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults

        init() throws {
            suiteName = "CrashLoopSafeModeTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
