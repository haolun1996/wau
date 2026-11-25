import AppKit
import Core
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var isDefaultBrowser = DefaultBrowser.isWau

    var body: some View {
        Form {
            Picker("Search engine:", selection: $preferences.searchEngineID) {
                ForEach(SearchEngine.all) { engine in
                    Text(engine.name).tag(engine.id)
                }
            }
            .pickerStyle(.menu)

            Picker("Links from other apps:", selection: $preferences.openLinksInLittleWau) {
                Text("Open in Little Wau").tag(true)
                Text("Open in a new tab").tag(false)
            }
            .pickerStyle(.radioGroup)

            LabeledContent("Default browser:") {
                if isDefaultBrowser {
                    Label("Wau is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Make Wau the Default Browser") {
                        Task {
                            await DefaultBrowser.makeWau()
                            isDefaultBrowser = DefaultBrowser.isWau
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isDefaultBrowser = DefaultBrowser.isWau }
    }
}

/// Whether Wau opens web links system-wide, and asking macOS to make it so.
@MainActor
enum DefaultBrowser {
    static var isWau: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS asks the user to confirm.
    static func makeWau() async {
        for scheme in ["http", "https"] {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
    }
}
