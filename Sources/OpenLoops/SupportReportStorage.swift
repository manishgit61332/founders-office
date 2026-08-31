import Foundation
import FounderOfficeCore

/// Performs support-report serialization and file I/O away from the UI actor.
/// The report is already a strict allow-list value, so this actor never reads
/// workspace files, logs, or other customer content while exporting it.
actor SupportReportStorage {
    func save(_ report: RedactedSupportReport, to destination: URL) throws {
        let payload = try report.encodedJSON()
        try payload.write(to: destination, options: .atomic)
    }

    func save(_ report: RedactedCrashStateReport, to destination: URL) throws {
        let payload = try report.encodedJSON()
        try payload.write(to: destination, options: .atomic)
    }
}
