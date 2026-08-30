import Testing
@testable import FounderOfficeCore

struct InteractionLeaseRegistryTests {
    @Test
    func testIndependentLeasesCannotReleaseEachOther() {
        var registry = InteractionLeaseRegistry()
        let calendarLease = registry.begin("calendar")
        let menuLease = registry.begin("menu")

        #expect(registry.isActive)
        #expect(registry.count == 2)

        registry.end(calendarLease)
        #expect(registry.isActive)
        #expect(registry.count == 1)

        registry.end(calendarLease)
        #expect(registry.count == 1)

        registry.end(menuLease)
        #expect(!registry.isActive)
    }

    @Test
    func testClearReleasesEveryLease() {
        var registry = InteractionLeaseRegistry()
        registry.begin("calendar")
        registry.begin("colour picker")

        registry.clear()

        #expect(!registry.isActive)
        #expect(registry.count == 0)
    }
}
