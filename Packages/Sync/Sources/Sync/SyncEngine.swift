import Core
import Foundation

/// What the engine remembers between syncs.
public struct SyncState: Codable, Equatable, Sendable {
    /// The merged document as of the last successful sync.
    public var document: SyncDocument
    /// This device's synced fields as of the last sync; changes are found by
    /// comparing against it.
    public var baseline: [String: SyncFields]
    public var deviceID: String
    public var lastSyncedAt: Date?
    /// Image files (by hash) this device has already uploaded.
    public var uploadedBlobs: Set<String>

    public init(
        document: SyncDocument = SyncDocument(), baseline: [String: SyncFields] = [:],
        deviceID: String = UUID().uuidString, lastSyncedAt: Date? = nil, uploadedBlobs: Set<String> = []
    ) {
        self.document = document
        self.baseline = baseline
        self.deviceID = deviceID
        self.lastSyncedAt = lastSyncedAt
        self.uploadedBlobs = uploadedBlobs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        document = try container.decode(SyncDocument.self, forKey: .document)
        baseline = try container.decode([String: SyncFields].self, forKey: .baseline)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        // Added with Easels; older saved states don't have it.
        uploadedBlobs = try container.decodeIfPresent(Set<String>.self, forKey: .uploadedBlobs) ?? []
    }
}

/// Where the engine keeps its `SyncState`.
public protocol SyncStateStore: Sendable {
    func loadSyncState() throws -> SyncState?
    func saveSyncState(_ state: SyncState?) throws
}

/// How the first sync on a device treats what's already on it.
public enum FirstSyncStrategy: Sendable {
    /// Keep this device's Spaces and add the synced ones.
    case merge
    /// Replace this device's Spaces and pinned tabs with the synced ones.
    case replaceLocal
}

/// A finished merge, waiting for the app to apply it and `commit`.
public struct SyncResult: Sendable {
    public let document: SyncDocument
    /// The records that should now exist locally.
    public var liveFields: [String: SyncFields] { document.liveFields }
    public let uploaded: Bool
}

/// Syncs records through one JSON file in a `RemoteStore`. Each sync records
/// local changes, merges with the remote copy (newest change wins per
/// record), and uploads the result if it differs. The app applies the
/// result, then calls `commit` so the next sync starts from it.
public actor SyncEngine {
    public static let fileName = "wau-sync.json"

    private let remote: any RemoteStore
    private let store: any SyncStateStore
    private let now: @Sendable () -> Date

    public init(remote: any RemoteStore, store: any SyncStateStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.remote = remote
        self.store = store
        self.now = now
    }

    /// Whether this device has completed a sync before.
    public func hasSyncedBefore() throws -> Bool {
        try store.loadSyncState()?.lastSyncedAt != nil
    }

    /// Whether the remote already holds synced data (to decide how the
    /// first sync should go).
    public func remoteHasData() async throws -> Bool {
        guard let document = try await downloadRemote() else { return false }
        return !document.liveFields.isEmpty
    }

    /// Merges `current` (this device's synced fields right now) with the
    /// remote copy and uploads the result if needed.
    public func sync(current: [String: SyncFields], firstSync strategy: FirstSyncStrategy = .merge) async throws -> SyncResult {
        let state = try store.loadSyncState() ?? SyncState()
        // Whole seconds, so timestamps survive the JSON round trip exactly.
        let timestamp = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))

        let local: SyncDocument
        if state.lastSyncedAt == nil, strategy == .replaceLocal {
            local = SyncDocument()
        } else {
            local = state.document.recording(current: current, baseline: state.baseline, deviceID: state.deviceID, at: timestamp)
        }

        let remoteData = try await remote.read(Self.fileName)
        let remoteDocument = try remoteData.map(Self.decode) ?? SyncDocument()
        let merged = SyncDocument.merge(local, remoteDocument)
        let mergedData = try Self.encode(merged)
        let needsUpload = mergedData != remoteData
        if needsUpload {
            try await remote.write(Self.fileName, mergedData)
        }
        return SyncResult(document: merged, uploaded: needsUpload)
    }

    /// Records that the app now matches `result`.
    public func commit(_ result: SyncResult) throws {
        var state = try store.loadSyncState() ?? SyncState()
        state.document = result.document
        state.baseline = result.liveFields
        state.lastSyncedAt = now()
        try store.saveSyncState(state)
    }

    /// Moves images (by content hash) that synced records refer to: uploads
    /// the ones this device has and hasn't sent yet, downloads the ones it
    /// lacks. Images are immutable, so each is transferred at most once.
    public func syncBlobs(
        needed: Set<String>,
        localData: @Sendable (String) -> Data?,
        storeDownloaded: @Sendable (String, Data) throws -> Void
    ) async throws {
        var state = try store.loadSyncState() ?? SyncState()
        for hash in needed.sorted() {
            if let data = localData(hash) {
                guard !state.uploadedBlobs.contains(hash) else { continue }
                try await remote.write(Self.blobName(hash), data)
                state.uploadedBlobs.insert(hash)
            } else if let data = try await remote.read(Self.blobName(hash)) {
                try storeDownloaded(hash, data)
                state.uploadedBlobs.insert(hash) // already on the remote
            }
        }
        try store.saveSyncState(state)
    }

    static func blobName(_ hash: String) -> String {
        "img-\(hash.filter(\.isHexDigit)).png"
    }

    /// Forgets everything synced (on sign-out); the next sync starts fresh.
    public func reset() throws {
        try store.saveSyncState(nil)
    }

    private func downloadRemote() async throws -> SyncDocument? {
        try await remote.read(Self.fileName).map(Self.decode)
    }

    static func encode(_ document: SyncDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> SyncDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncDocument.self, from: data)
    }
}
