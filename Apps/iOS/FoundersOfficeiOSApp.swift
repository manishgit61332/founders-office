import SwiftUI

@main
struct FoundersOfficeiOSApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var calendar = CalendarProvider()
    @StateObject private var account = IOSAccountController()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .environmentObject(calendar)
                .environmentObject(account)
                .tint(model.personalization.resolvedAppearance.primaryAccentColor)
                .font(model.personalization.resolvedAppearance.interfaceFont(.secondary))
                .preferredColorScheme(
                    model.personalization.resolvedAppearance.surfaceStyleID == .solidBlack
                        ? .dark
                        : nil
                )
                .task(id: model.workspaceSession?.snapshot.workspaceID) {
                    guard let session = model.workspaceSession else { return }
                    account.configure(
                        repository: session.repository,
                        hasLocalCustomerData: { model.hasCustomerData },
                        workspaceName: { model.personalization.resolvedWorkspaceName },
                        workspaceChanged: model.refreshWorkspace
                    )
                }
                .onChange(of: account.authState) { _, state in
                    model.setWidgetAccountState(state)
                }
                .onChange(of: calendar.events) { _, events in
                    _ = events
                    model.updateWidgetCalendar(nextEvent: calendar.upNextEvent)
                }
                .onAppear {
                    model.updateWidgetCalendar(nextEvent: calendar.upNextEvent)
                }
                .onOpenURL { model.handleDeepLink($0) }
        }
    }
}
