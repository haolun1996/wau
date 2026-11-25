import AppKit
import AuthenticationServices
import Core
import OSLog
import Storage
import Sync

/// Runs Google Drive sync for the app: signing in and out, deciding when to
/// sync, and applying what comes back to the browser window.
@MainActor
final class SyncCoordinator: NSObject, ObservableObject {
    enum Status: Equatable {
        /// This build has no Google client ID.
        case notConfigured
        case signedOut
        case signingIn
        case syncing
        case idle
        case failed(String)
    }

    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "Sync")
    private static let interval: Duration = .seconds(5 * 60)
    private static let changeDelay: Duration = .seconds(20)

    @Published private(set) var status: Status
    @Published private(set) var email: String?
    @Published private(set) var lastSyncedAt: Date?

    private let config: GoogleOAuthConfig?
    private let database: AppDatabase
    private let keychain = KeychainTokenStore()
    /// The window whose Spaces are synced.
    private weak var window: BrowserWindowController?
    private var engine: SyncEngine?
    private var periodicTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var isSyncing = false
    private var authSession: ASWebAuthenticationSession?

    init(database: AppDatabase) {
        self.database = database
        config = GoogleOAuthConfig(clientID: Bundle.main.object(forInfoDictionaryKey: "WauGoogleClientID") as? String)
        status = config == nil ? .notConfigured : .signedOut
        super.init()
    }

    var isSignedIn: Bool { engine != nil }

    /// Connects to the window and, if a Google account is remembered, syncs.
    func start(with window: BrowserWindowController) {
        self.window = window
        guard let config, let tokens = keychain.load() else { return }
        connect(config: config, tokens: tokens)
        status = .idle
        syncSoon(after: .seconds(2))
        startPeriodicSync()
    }

    // MARK: Signing in and out

    func signIn() {
        guard let config else { status = .notConfigured; return }
        let pkce = PKCE()
        let state = UUID().uuidString
        let url = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: state)
        status = .signingIn
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: config.redirectScheme) { [weak self] callback, error in
            Task { @MainActor in
                await self?.finishSignIn(callback: callback, error: error, pkce: pkce, state: state, config: config)
            }
        }
        session.presentationContextProvider = self
        authSession = session
        if !session.start() {
            status = .failed("Couldn't open the Google sign-in window.")
        }
    }

    private func finishSignIn(callback: URL?, error: Error?, pkce: PKCE, state: String, config: GoogleOAuthConfig) async {
        authSession = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            status = .signedOut
            return
        }
        do {
            guard let callback else { throw error ?? SyncError.signInFailed("no response") }
            let code = try GoogleOAuth.authorizationCode(from: callback, expectedState: state)
            let (data, response) = try await URLSession.shared.send(GoogleOAuth.tokenRequest(code: code, pkce: pkce, config: config))
            guard response.statusCode == 200 else {
                throw SyncError.signInFailed(String(decoding: data.prefix(200), as: UTF8.self))
            }
            let tokens = try GoogleOAuth.tokens(from: data)
            keychain.save(tokens)
            connect(config: config, tokens: tokens)
            try await firstSync()
            startPeriodicSync()
        } catch {
            Self.logger.error("Sign-in failed: \(error)")
            status = .failed(error.localizedDescription)
        }
    }

    /// On the first sync, if Drive already has Spaces from another Mac, ask
    /// whether to merge them with this Mac's or replace this Mac's.
    private func firstSync() async throws {
        guard let engine else { return }
        var strategy = FirstSyncStrategy.merge
        if try await !engine.hasSyncedBefore(), try await engine.remoteHasData() {
            let alert = NSAlert()
            alert.messageText = "Your Google Drive already has Wau Spaces"
            alert.informativeText = "They were synced from another Mac. Merge them with this Mac's Spaces, or replace this Mac's Spaces and pinned tabs with them? Ordinary open tabs are kept either way."
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace This Mac's")
            strategy = alert.runModal() == .alertSecondButtonReturn ? .replaceLocal : .merge
        }
        await sync(strategy: strategy)
    }

    func signOut() {
        periodicTask?.cancel()
        pendingTask?.cancel()
        let engine = engine
        self.engine = nil
        keychain.delete()
        email = nil
        lastSyncedAt = nil
        status = config == nil ? .notConfigured : .signedOut
        Task { try? await engine?.reset() }
    }

    private func connect(config: GoogleOAuthConfig, tokens: GoogleTokens) {
        let keychain = keychain
        let session = GoogleSession(config: config, tokens: tokens, transport: URLSession.shared) { keychain.save($0) }
        let drive = GoogleDriveStore(session: session, transport: URLSession.shared)
        engine = SyncEngine(remote: drive, store: DatabaseSyncStateStore(database: database))
        email = tokens.email
    }

    // MARK: Syncing

    /// Called when the browser's Spaces may have changed.
    func setNeedsSync() {
        guard engine != nil else { return }
        syncSoon(after: Self.changeDelay)
    }

    func syncNow() {
        pendingTask?.cancel()
        Task { await sync() }
    }

    private func syncSoon(after delay: Duration) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func startPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                await self?.sync()
            }
        }
    }

    private func sync(strategy: FirstSyncStrategy = .merge) async {
        guard let engine, let window, !isSyncing else { return }
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        let before = Self.syncedFields(of: window)
        do {
            let result = try await engine.sync(current: before, firstSync: strategy)
            // If Spaces changed while waiting on the network, applying now
            // would undo that change; try again shortly instead.
            guard Self.syncedFields(of: window) == before else {
                status = .idle
                syncSoon(after: .seconds(3))
                return
            }
            let updated = SyncMapping.apply(result.liveFields, to: window.model.snapshot)
            if updated != window.model.snapshot {
                let removedProfiles = window.applySyncedState(updated)
                for profile in removedProfiles {
                    await Profiles.erase(profile)
                }
            }
            window.easels.replaceAll(with: SyncMapping.easels(from: result.liveFields))
            try await engine.commit(result)
            try await syncImages(engine: engine, easels: window.easels)
            lastSyncedAt = Date()
            status = .idle
        } catch SyncError.notSignedIn {
            Self.logger.notice("Google access ended; signing out")
            signOut()
            status = .failed("Google access ended. Sign in again to keep syncing.")
        } catch {
            Self.logger.error("Sync failed: \(error)")
            status = .failed(error.localizedDescription)
        }
    }
}

extension SyncCoordinator {
    /// Everything that syncs: Spaces, pinned tabs and favorites, and Easels.
    static func syncedFields(of window: BrowserWindowController) -> [String: SyncFields] {
        SyncMapping.fields(from: window.model.snapshot)
            .merging(SyncMapping.fields(from: window.easels.snapshot)) { $1 }
    }

    /// Uploads new Easel images and downloads ones this Mac is missing.
    func syncImages(engine: SyncEngine, easels: EaselStore) async throws {
        let images = easels.images
        let needed = easels.snapshot.imageHashes
        let missing = needed.filter { !images.contains($0) }
        try await engine.syncBlobs(
            needed: needed,
            localData: { images.data(for: $0) },
            storeDownloaded: { hash, data in try images.save(data, hash: hash) }
        )
        for hash in missing where images.contains(hash) {
            easels.imageArrived(hash)
        }
    }
}

extension SyncCoordinator: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            window?.window ?? NSApp.keyWindow ?? NSWindow()
        }
    }
}

/// Keeps the sync engine's state in Wau's database.
struct DatabaseSyncStateStore: SyncStateStore {
    let database: AppDatabase
    private static let key = "state"

    func loadSyncState() throws -> SyncState? {
        guard let data = try database.syncValue(forKey: Self.key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncState.self, from: data)
    }

    func saveSyncState(_ state: SyncState?) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try database.setSyncValue(state.map { try encoder.encode($0) }, forKey: Self.key)
    }
}
