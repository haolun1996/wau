import Core
import Foundation
import Testing
@testable import Storage

@Suite("Easel storage")
struct EaselStorageTests {
    @Test func easelsAndItemsRoundTripAndDeleteTogether() throws {
        let database = try AppDatabase.inMemory()
        let easel = Easel(spaceID: UUID(), title: "Ideas", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let image = EaselItem(easelID: easel.id, kind: .image, x: 1, y: 2, width: 300, height: 200, z: 0,
                              text: "Clip", url: URL(string: "https://example.com"), imageHash: "ab12")
        let label = EaselItem(easelID: easel.id, kind: .text, x: 5, y: 6, width: 100, height: 30, z: 1, text: "Note")
        try database.saveEasel(easel)
        try database.saveEaselItem(image)
        try database.saveEaselItem(label)
        #expect(try database.loadEasels() == EaselSnapshot(easels: [easel], items: [image, label]))

        try database.deleteEaselItem(id: label.id)
        #expect(try database.loadEasels().items == [image])
        try database.deleteEasel(id: easel.id)
        #expect(try database.loadEasels() == EaselSnapshot())
    }

    @Test func drawingsKeepTheirPoints() throws {
        let database = try AppDatabase.inMemory()
        let easel = Easel(spaceID: UUID(), title: "Sketch", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let stroke = EaselItem(easelID: easel.id, kind: .drawing, x: 1, y: 2, width: 80, height: 60, z: 0,
                               points: [EaselPoint(x: 0, y: 0), EaselPoint(x: 0.5, y: 0.75), EaselPoint(x: 1, y: 1)])
        try database.saveEasel(easel)
        try database.saveEaselItem(stroke)
        #expect(try database.loadEasels().items == [stroke])
    }

    @Test func labelsKeepTheirTextSize() throws {
        let database = try AppDatabase.inMemory()
        let easel = Easel(spaceID: UUID(), title: "Notes", createdAt: Date(timeIntervalSince1970: 1_790_000_000), position: 2)
        let fixed = EaselItem(easelID: easel.id, kind: .text, x: 0, y: 0, width: 300, height: 200, z: 0, text: "Dada",
                              fontSize: 32, color: "#3E8CF0")
        let fitting = EaselItem(easelID: easel.id, kind: .text, x: 0, y: 300, width: 300, height: 200, z: 1, text: "Fit")
        try database.saveEasel(easel)
        try database.saveEaselItem(fixed)
        try database.saveEaselItem(fitting)
        #expect(try database.loadEasels().items == [fixed, fitting])
    }

    @Test func saveEaselsReplacesEverything() throws {
        let database = try AppDatabase.inMemory()
        try database.saveEasel(Easel(spaceID: UUID(), title: "Old"))
        let replacement = EaselSnapshot(easels: [Easel(spaceID: UUID(), title: "New", createdAt: Date(timeIntervalSince1970: 1_790_000_000))])
        try database.saveEasels(replacement)
        #expect(try database.loadEasels() == replacement)
    }

    @Test func imagesAreStoredByContentHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageStore(directory: directory)
        let data = Data("png bytes".utf8)

        let hash = try store.save(data)
        #expect(hash == ImageStore.hash(of: data))
        #expect(hash.count == 64)
        #expect(store.contains(hash))
        #expect(store.data(for: hash) == data)
        #expect(throws: (any Error).self) { try store.save(Data("other".utf8), hash: hash) } // must match its name
        #expect(!store.contains(String(repeating: "0", count: 64)))
    }
}
