import Foundation
import OSLog
import Storage

/// Records page visits into history as tabs load and retitle.
@MainActor
final class HistoryRecorder {
    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "History")

    private let database: AppDatabase
    /// The title last written for each recorded URL, to skip redundant writes.
    private var recordedTitles: [URL: String] = [:]

    init(database: AppDatabase) {
        self.database = database
    }

    /// A page finished loading: count a visit.
    func pageLoaded(_ tab: Tab) {
        guard let url = tab.url, Self.isRecordable(url) else { return }
        let title = tab.title
        if recordedTitles.count > 500 { recordedTitles.removeAll() }
        recordedTitles[url] = title
        Task {
            do {
                try await database.recordVisit(url: url, title: title)
            } catch {
                Self.logger.error("Recording a visit failed: \(error)")
            }
        }
    }

    /// The tab's title may have changed after loading; keep history in step.
    func tabChanged(_ tab: Tab) {
        guard let url = tab.url, let recorded = recordedTitles[url], recorded != tab.title else { return }
        let title = tab.title
        recordedTitles[url] = title
        Task { try? await database.updateHistoryTitle(url: url, title: title) }
    }

    static func isRecordable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
