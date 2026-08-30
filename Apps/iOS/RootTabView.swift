import SwiftUI

struct RootTabView: View {
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
    }
}
