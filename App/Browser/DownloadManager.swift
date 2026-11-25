import AppKit
import OSLog
import WebKit

/// Saves downloads into ~/Downloads and keeps a short list of recent ones.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "Downloads")
    private static let historyLimit = 20

    struct Entry: Identifiable {
        enum State: Equatable {
            case downloading
            case finished
            case failed(String)
        }

        let id = UUID()
        var filename: String
        var destination: URL?
        var state: State
        weak var progress: Progress?
    }

    private(set) var entries: [Entry] = []
    private var ids: [ObjectIdentifier: UUID] = [:]

    /// Shows a message to the user, with a file to reveal if there is one.
    var onNotice: ((String, URL?) -> Void)?

    func start(_ download: WKDownload) {
        download.delegate = self
        let entry = Entry(filename: download.originalRequest?.url?.lastPathComponent ?? "Download", state: .downloading, progress: download.progress)
        ids[ObjectIdentifier(download)] = entry.id
        entries.insert(entry, at: 0)
        if entries.count > Self.historyLimit { entries.removeLast() }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let destination = Self.uniqueDestination(for: suggestedFilename)
        update(download) { entry in
            entry.filename = destination.lastPathComponent
            entry.destination = destination
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        update(download) { $0.state = .finished }
        guard let entry = entry(for: download) else { return }
        // Makes the Downloads stack in the Dock bounce, as Safari does.
        if let destination = entry.destination {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
        }
        onNotice?("Downloaded “\(entry.filename)”", entry.destination)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        Self.logger.error("Download failed: \(error)")
        update(download) { $0.state = .failed(error.localizedDescription) }
        onNotice?("Download failed: \(entry(for: download)?.filename ?? "file")", nil)
    }

    // MARK: Helpers

    private func entry(for download: WKDownload) -> Entry? {
        guard let id = ids[ObjectIdentifier(download)] else { return nil }
        return entries.first { $0.id == id }
    }

    private func update(_ download: WKDownload, _ change: (inout Entry) -> Void) {
        guard let id = ids[ObjectIdentifier(download)], let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// `~/Downloads/name.ext`, or `name 2.ext` and so on if taken.
    static func uniqueDestination(for suggestedFilename: String, in directory: URL? = nil) -> URL {
        let folder = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Never let a server-chosen name escape the folder.
        let safeName = suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let name = safeName.isEmpty ? "Download" : safeName
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }
}

/// Window ▸ Downloads: recent downloads; choosing one shows it in Finder.
@MainActor
final class DownloadsMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = DownloadManager.shared.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No Downloads", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in entries {
            var title = entry.filename
            switch entry.state {
            case .downloading:
                if let fraction = entry.progress?.fractionCompleted { title += " — \(Int(fraction * 100))%" }
            case .failed:
                title += " — failed"
            case .finished:
                break
            }
            let item = ClosureMenuItem(title) {
                if let url = entry.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            item.isEnabled = entry.destination != nil && entry.state != .downloading
            if let destination = entry.destination {
                item.image = NSWorkspace.shared.icon(forFile: destination.path)
                item.image?.size = NSSize(width: 16, height: 16)
            }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open Downloads Folder") {
            NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        })
    }
}
