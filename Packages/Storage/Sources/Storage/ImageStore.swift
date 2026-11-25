import CryptoKit
import Foundation

/// Easel images on disk, named by the SHA-256 of their contents, so the
/// same picture is stored (and synced) once however often it's used.
public struct ImageStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores `data` and returns its hash.
    @discardableResult
    public func save(_ data: Data) throws -> String {
        let hash = Self.hash(of: data)
        try save(data, hash: hash)
        return hash
    }

    /// Stores data that arrived under `hash` (from sync), if it really matches.
    public func save(_ data: Data, hash: String) throws {
        guard Self.hash(of: data) == hash else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
    }

    public func data(for hash: String) -> Data? {
        try? Data(contentsOf: fileURL(for: hash))
    }

    public func contains(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: hash).path)
    }

    func fileURL(for hash: String) -> URL {
        // Hashes are hex, so they're safe as file names.
        directory.appendingPathComponent(hash.filter(\.isHexDigit) + ".png")
    }
}
