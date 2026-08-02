import SwiftUI

@main
struct CistilkaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Cistilka") {
            ContentView()
                .environment(model)
        }
        Settings {
            TabView {
                GeneralSettingsView()
                    .environment(model)
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                AccountsSettingsView()
                    .environment(model)
                    .tabItem {
                        Label("Accounts", systemImage: "person.crop.circle")
                    }
            }
            .frame(minWidth: 460, minHeight: 380)
        }
    }
}
