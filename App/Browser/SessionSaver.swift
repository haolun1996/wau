import Core
import OSLog
import Storage

/// Saves a window's tabs shortly after they change, so a burst of changes
/// (a page loading, several tabs opening) is written once.
@MainActor
final class SessionSaver {
    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "Session")
    private static let delay: Duration = .seconds(1)

    private let database: AppDatabase
    private let snapshot: () -> BrowserSnapshot
    private var pending: Task<Void, Never>?

    init(database: AppDatabase, snapshot: @escaping () -> BrowserSnapshot) {
        self.database = database
        self.snapshot = snapshot
    }

    /// Schedules a save, replacing any save already scheduled.
    func setNeedsSave() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            let snapshot = snapshot()
            do {
                try await database.saveBrowser(snapshot)
            } catch {
                Self.logger.error("Saving session failed: \(error)")
            }
        }
    }

    /// Saves immediately; used when the app quits.
    func saveNow() {
        pending?.cancel()
        pending = nil
        do {
            try database.saveBrowser(snapshot())
        } catch {
            Self.logger.error("Saving session failed: \(error)")
        }
    }
}
