import SwiftUI

@main
struct FoundersOfficeiOSApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var calendar = CalendarProvider()
    @StateObject private var cloudAccount = CloudAccountMonitor()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .environmentObject(calendar)
                .environmentObject(cloudAccount)
                .tint(model.personalization.accent.swiftUIColor)
        }
    }
}
