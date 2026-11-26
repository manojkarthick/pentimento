import SwiftUI

@main struct PentimentoApp: App {
    @StateObject private var library = PhotoLibrary()
    @AppStorage("appearance") private var appearance = "auto"
    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 700, minHeight: 480)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photos…") { library.openPanel() }.keyboardShortcut("o")
                Button("Clear Recently Opened Photos") { library.clearRecent() }
            }
        }
        Settings { SettingsView(library: library) }
    }
}

private struct SettingsView: View {
    @ObservedObject var library: PhotoLibrary
    @AppStorage("appearance") private var appearance = "auto"
    var body: some View {
        Form {
            Picker("Theme", selection: $appearance) {
                Text("Auto").tag("auto")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Button("Clear Recently Opened Photos") {
                library.clearRecent()
            }
        }
        .padding(24)
        .frame(width: 420, height: 180)
    }
}
