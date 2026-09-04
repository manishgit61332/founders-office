import Foundation
import FounderOfficeCore
import Testing

enum TestFixtures {
    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    static func loop(
        id: UUID = UUID(),
        title: String = "Move",
        details: String = "",
        status: LoopStatus = .next,
        previousStatus: LoopStatus? = nil,
        priority: LoopPriority = .p1,
        dueAt: Date? = nil,
        createdAt: Date = date(0),
        updatedAt: Date = date(10),
        completedAt: Date? = nil,
        deletedAt: Date? = nil,
        source: String = "test"
    ) -> OpenLoop {
        OpenLoop(
            id: id,
            title: title,
            details: details,
            status: status,
            previousStatus: previousStatus,
            priority: priority,
            dueAt: dueAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            deletedAt: deletedAt,
            source: source
        )
    }

    static func document(
        schemaVersion: Int = 3,
        updatedAt: Date = date(10),
        items: [OpenLoop]
    ) -> OpenLoopsDocument {
        OpenLoopsDocument(
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            items: items
        )
    }

    static func personalization(
        updatedAt: Date?,
        preferredName: String? = nil,
        workspaceName: String? = nil
    ) -> PersonalizationDocument {
        PersonalizationDocument(
            schemaVersion: 6,
            displayName: "Founder's Office",
            accent: .blue,
            iconStyle: .system,
            photoFileName: nil,
            primaryGoal: nil,
            milestones: [],
            updatedAt: updatedAt,
            preferredName: preferredName,
            workspaceName: workspaceName,
            appearance: .preset(.native)
        )
    }

    static func calendarDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return try #require(calendar.date(from: components))
    }
}
