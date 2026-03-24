import SwiftUI

@main
struct AresApp: App {
    init() {
        FontRegistration.registerAll()
        UserDefaults.standard.set(false, forKey: "showSettings")
        UserDefaults.standard.register(defaults: [
            "terrainSourceMode": TerrainSource.prebaked.rawValue,
            "hasCompletedSetup": false,
        ])
        // Disable tabbing — single-window app
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @AppStorage("showSettings") private var showSettings = false

    var body: some Scene {
        Window("Ares Preview", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Settings
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Remove File, Edit, Help menus
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .help) {}
        }
    }
}
