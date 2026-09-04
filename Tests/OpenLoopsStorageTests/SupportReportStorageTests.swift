import Foundation
import FounderOfficeCore
import Testing
@testable import OpenLoops

struct SupportReportStorageTests {
    @Test
    func savesTheAllowListedReportAndAtomicallyReplacesAnExistingExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("support.json")
        try Data("partial-old-export".utf8).write(to: destination)
        let storage = SupportReportStorage()
        let firstID = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let secondID = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))

        try await storage.save(report(incidentID: firstID), to: destination)
        try await storage.save(report(incidentID: secondID), to: destination)

        let payload = try Data(contentsOf: destination)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: String])
        #expect(object.keys.sorted() == RedactedSupportReport.fieldKeys.sorted())
        #expect(object["incident_id"] == secondID.uuidString.lowercased())
        #expect(!payload.contains(Data("partial-old-export".utf8)))
    }

    @Test
    func savesCrashStateDiagnosticWithoutOpeningOrAcceptingWorkspaceData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("crash-state.json")
        let incidentID = try #require(
            UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        )
        let report = RedactedCrashStateReport(
            incidentID: incidentID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            consecutivePreReadyFailures: 3,
            metadata: SupportReportMetadata(
                appVersion: "1.2.3",
                buildNumber: "45",
                operatingSystemMajor: 15,
                operatingSystemMinor: 6,
                operatingSystemPatch: 0,
                architecture: .arm64
            )
        )

        try await SupportReportStorage().save(report, to: destination)

        let payload = try Data(contentsOf: destination)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: String])
        #expect(object.keys.sorted() == RedactedCrashStateReport.fieldKeys.sorted())
        #expect(object["incident_id"] == incidentID.uuidString.lowercased())
        #expect(!payload.contains(Data("workspace".utf8)))
    }

    private func report(incidentID: UUID) -> RedactedSupportReport {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return RedactedSupportReport(
            snapshot: HealthSnapshot(
                capturedAt: capturedAt,
                components: HealthComponent.allCases.map {
                    HealthComponentStatus(
                        component: $0,
                        condition: .ready,
                        detail: "Ready",
                        lastSuccessAt: capturedAt
                    )
                }
            ),
            metadata: SupportReportMetadata(
                appVersion: "1.2.3",
                buildNumber: "45",
                operatingSystemMajor: 15,
                operatingSystemMinor: 6,
                operatingSystemPatch: 0,
                architecture: .arm64
            ),
            incidentID: incidentID
        )
    }
}
