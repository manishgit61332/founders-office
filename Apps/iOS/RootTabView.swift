import FounderOfficeCore
import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                LoopsView()
            }
            .tabItem {
                Label("Moves", systemImage: "checklist")
            }

            NavigationStack {
                CalendarView()
            }
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
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
                    .font(.headline)

                Text("\(message) Editing and iCloud sync are paused to protect it.")
                    .font(.body)
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
            "Workspace recovery required. \(message) Editing and iCloud sync are paused to protect it."
        )
    }
}
