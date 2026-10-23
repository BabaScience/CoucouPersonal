import SwiftUI
import AppKit

@main
struct NotchBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        #if !APPSTORE
        // `Coucou --screen-tool …`: the screen assistant's command, run by Claude (ScreenTool.swift).
        if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--screen-tool" {
            ScreenTool.main(Array(CommandLine.arguments.dropFirst(2)))
        }
        #endif
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
        #if !APPSTORE
        .commands {
            // ⌘, and Coucou → Settings… open the notch's pages of the Coucou window.
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("Settings…", comment: "")) {
                    delegate.openSettings()
                }
                .keyboardShortcut(",")
            }
        }
        #endif
    }
}
