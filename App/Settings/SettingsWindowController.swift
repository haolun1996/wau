import AppKit
import SwiftUI

/// Wau ▸ Settings… (⌘,).
@MainActor
final class SettingsWindowController: NSWindowController {
    init(sync: SyncCoordinator, preferences: Preferences) {
        let host = NSHostingController(rootView: SettingsView(sync: sync, preferences: preferences))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "Wau Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct SettingsView: View {
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }
            SyncSettingsView(sync: sync)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct SyncSettingsView: View {
    @ObservedObject var sync: SyncCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Google Drive Sync").font(.title3.weight(.semibold))
            Text("Your Spaces (names, icons, themes), pinned tabs and favorites sync through a private folder in your Google Drive that only Wau can see. Open tabs, history, passwords and site logins stay on this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch sync.status {
            case .notConfigured:
                notConfigured
            case .signedOut, .signingIn:
                Button {
                    sync.signIn()
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                }
                .controlSize(.large)
                .disabled(sync.status == .signingIn)
            case .syncing, .idle, .failed:
                signedIn
            }

            if case .failed(let message) = sync.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !sync.isSignedIn {
                    Button("Sign in with Google") { sync.signIn() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var signedIn: some View {
        if sync.isSignedIn {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(sync.email ?? "Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Group {
                        if sync.status == .syncing {
                            Text("Syncing…")
                        } else if let last = sync.lastSyncedAt {
                            Text("Last synced \(last, style: .relative) ago")
                        } else {
                            Text("Not synced yet")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") { sync.syncNow() }
                    .disabled(sync.status == .syncing)
                Button("Sign Out") { sync.signOut() }
            }
        }
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This build of Wau has no Google client ID.", systemImage: "info.circle")
            Text("""
            1. In Google Cloud Console, create a project and enable the Google Drive API.
            2. Set up the OAuth consent screen and add yourself as a test user.
            3. Create an OAuth client of type “iOS” with bundle ID dev.wau.Wau.
            4. Copy Config/Local.xcconfig.example to Config/Local.xcconfig, paste the client ID, and rebuild.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
