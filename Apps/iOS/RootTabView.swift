import FounderOfficeCore
import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(0)

            NavigationStack {
                LoopsView()
            }
            .tabItem {
                Label("Moves", systemImage: "checklist")
            }
            .tag(1)

            NavigationStack {
                CalendarView()
            }
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(3)
        }
        .onAppear { selectTab(for: model.route) }
        .onChange(of: model.route) { _, route in selectTab(for: route) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let recoveryMessage = model.recoveryMessage {
                WorkspaceRecoveryBanner(
                    message: recoveryMessage,
                    appearance: model.personalization.resolvedAppearance
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private func selectTab(for route: IOSAppRoute?) {
        switch route {
        case .home: selectedTab = 0
        case .moves: selectedTab = 1
        case .calendar: selectedTab = 2
        case .goal: selectedTab = 3
        case nil: break
        }
    }
}

private struct WorkspaceRecoveryBanner: View {
    let message: String
    let appearance: AppearancePreferences

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace recovery required")
                    .font(appearance.interfaceFont(.secondary, weight: .semibold))

                Text("\(message) Editing and device sync are paused to protect it.")
                    .font(appearance.interfaceFont(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .foregroundStyle(.primary)
        .background(
            appearance.nodeBackgroundColor,
            in: RoundedRectangle(
                cornerRadius: appearance.nodeCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: appearance.nodeCornerRadius,
                style: .continuous
            )
            .stroke(.orange.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Workspace recovery required. \(message) Editing and device sync are paused to protect it."
        )
    }
}
