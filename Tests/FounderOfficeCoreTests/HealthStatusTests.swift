import Foundation
import Testing
@testable import FounderOfficeCore

struct HealthStatusTests {
    @Test
    func snapshotUsesOneStableSlotPerComponent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = HealthSnapshot(
            capturedAt: now,
            components: [
                HealthComponentStatus(
                    component: .calendar,
                    condition: .ready,
                    detail: "Calendar is ready"
                ),
                HealthComponentStatus(
                    component: .localData,
                    condition: .ready,
                    detail: "Local data is ready"
                ),
                HealthComponentStatus(
                    component: .calendar,
                    condition: .attention,
                    detail: "Latest calendar status wins"
                )
            ]
        )

        #expect(snapshot.components.map(\.component) == [.localData, .calendar])
        #expect(snapshot[.calendar]?.condition == .attention)
    }

    @Test
    func supportReportExportsOnlyTheExplicitAllowList() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = completeSnapshot(at: now)
        let report = RedactedSupportReport(
            snapshot: snapshot,
            metadata: SupportReportMetadata(
                appVersion: "1.2.3",
                buildNumber: "45",
                operatingSystemMajor: 15,
                operatingSystemMinor: 6,
                operatingSystemPatch: 0,
                architecture: .arm64
            ),
            incidentID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )

        #expect(report.fields.map(\.key) == RedactedSupportReport.fieldKeys)
        let data = try report.encodedJSON()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object.keys.sorted() == RedactedSupportReport.fieldKeys.sorted())
        #expect(object["incident_id"] == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test
    func supportReportCannotCarryDisplayDetailsOrUserContent() throws {
        let marker = "PRIVATE-MOVE EVENT-TITLE PERSON-NAME /Users/example secret-token"
        let snapshot = HealthSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            components: HealthComponent.allCases.map {
                HealthComponentStatus(
                    component: $0,
                    condition: .attention,
                    detail: marker,
                    remediation: .none
                )
            }
        )
        let report = RedactedSupportReport(
            snapshot: snapshot,
            metadata: SupportReportMetadata(
                appVersion: "1.0 PRIVATE",
                buildNumber: "7 /Users/example",
                operatingSystemMajor: 15,
                operatingSystemMinor: 6,
                operatingSystemPatch: 0,
                architecture: .arm64
            )
        )
        let text = try #require(String(data: report.encodedJSON(), encoding: .utf8))

        #expect(!text.contains(marker))
        #expect(!text.contains("/Users/"))
        #expect(!text.localizedCaseInsensitiveContains("secret-token"))
        #expect(!text.localizedCaseInsensitiveContains("private"))
        #expect(!text.localizedCaseInsensitiveContains("token"))
        #expect(!text.localizedCaseInsensitiveContains("PERSON-NAME"))
        #expect(!text.localizedCaseInsensitiveContains("EVENT-TITLE"))
    }

    @Test
    func remediationSetCannotMutateCanonicalDataOrCredentials() {
        let allowed = Set(HealthRemediation.allCases)
        #expect(allowed == [
            .none,
            .reloadLocalData,
            .retrySync,
            .refreshCalendar,
            .openCalendarSettings,
            .openLoginItemsSettings,
            .recheckAssistant
        ])
    }

    private func completeSnapshot(at date: Date) -> HealthSnapshot {
        HealthSnapshot(
            capturedAt: date,
            components: HealthComponent.allCases.map {
                HealthComponentStatus(
                    component: $0,
                    condition: .ready,
                    detail: "Ready",
                    lastSuccessAt: date,
                    remediation: .none
                )
            }
        )
    }
}
