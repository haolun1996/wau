import AppKit
import Core
import OSLog
import Storage

/// Every Easel and its items, kept in the database; images live in an
/// `ImageStore` on disk.
@MainActor
final class EaselStore {
    private static let logger = Logger(subsystem: "dev.wau.Wau", category: "Easels")
    /// New clippings are scaled to fit this width on the canvas.
    private static let maxImageWidth: Double = 520

    let images: ImageStore
    private let database: AppDatabase
    private(set) var snapshot: EaselSnapshot
    private let imageCache = NSCache<NSString, NSImage>()

    /// Easels were added, removed or renamed.
    var onChange: (() -> Void)?
    /// An Easel's items changed.
    var onItemsChange: ((UUID) -> Void)?

    init(database: AppDatabase, images: ImageStore) {
        self.database = database
        self.images = images
        do {
            snapshot = try database.loadEasels()
        } catch {
            Self.logger.error("Loading Easels failed: \(error)")
            snapshot = EaselSnapshot()
        }
    }

    /// A Space's Easels in their sidebar order.
    func easels(in spaceID: UUID) -> [Easel] {
        snapshot.easels.filter { $0.spaceID == spaceID }
            .sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    func easel(withID id: UUID) -> Easel? {
        snapshot.easels.first { $0.id == id }
    }

    func items(in easelID: UUID) -> [EaselItem] {
        snapshot.items.filter { $0.easelID == easelID }.sorted { $0.z < $1.z }
    }

    // MARK: Easels

    @discardableResult
    func createEasel(in spaceID: UUID, title: String = "Easel") -> Easel {
        // New Easels go to the end of the list.
        let last = easels(in: spaceID).map(\.position).max() ?? 0
        let easel = Easel(spaceID: spaceID, title: title, position: last + 1)
        snapshot.easels.append(easel)
        persist { try $0.saveEasel(easel) }
        onChange?()
        return easel
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = snapshot.easels.firstIndex(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.easels[index].title = title.isEmpty ? "Easel" : title
        let easel = snapshot.easels[index]
        persist { try $0.saveEasel(easel) }
        onChange?()
    }

    /// Moves an Easel to `gap` among its Space's Easels (0 is the top), and
    /// renumbers them so the order saves and syncs.
    func move(_ id: UUID, toGap gap: Int) {
        guard let moving = easel(withID: id) else { return }
        var ordered = easels(in: moving.spaceID)
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        ordered.remove(at: from)
        // Gaps after the Easel's old place shift up by one once it's lifted out.
        let target = min(max(gap > from ? gap - 1 : gap, 0), ordered.count)
        ordered.insert(moving, at: target)
        var changed: [Easel] = []
        for (number, easel) in ordered.enumerated() where easel.position != number + 1 {
            guard let index = snapshot.easels.firstIndex(where: { $0.id == easel.id }) else { continue }
            snapshot.easels[index].position = number + 1
            changed.append(snapshot.easels[index])
        }
        guard !changed.isEmpty else { return }
        persist { database in try changed.forEach(database.saveEasel) }
        onChange?()
    }

    func delete(_ id: UUID) {
        snapshot.easels.removeAll { $0.id == id }
        snapshot.items.removeAll { $0.easelID == id }
        persist { try $0.deleteEasel(id: id) }
        onChange?()
    }

    func deleteEasels(inSpace spaceID: UUID) {
        for easel in easels(in: spaceID) { delete(easel.id) }
    }

    // MARK: Items

    /// Adds `item` in front of everything else on its Easel.
    @discardableResult
    func add(_ item: EaselItem) -> EaselItem {
        var item = item
        item.z = (items(in: item.easelID).map(\.z).max() ?? -1) + 1
        snapshot.items.append(item)
        persist { try $0.saveEaselItem(item) }
        onItemsChange?(item.easelID)
        return item
    }

    func update(_ item: EaselItem) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else { return }
        snapshot.items[index] = item
        persist { try $0.saveEaselItem(item) }
        onItemsChange?(item.easelID)
    }

    func bringToFront(_ id: UUID) {
        guard var item = snapshot.items.first(where: { $0.id == id }) else { return }
        let top = items(in: item.easelID).map(\.z).max() ?? 0
        guard item.z < top else { return }
        item.z = top + 1
        update(item)
    }

    func remove(_ id: UUID) {
        guard let item = snapshot.items.first(where: { $0.id == id }) else { return }
        snapshot.items.removeAll { $0.id == id }
        persist { try $0.deleteEaselItem(id: id) }
        onItemsChange?(item.easelID)
    }

    /// Saves a PNG and places it on an Easel, scaled to a comfortable size.
    /// `center` is in canvas points; nil puts it near the top left.
    @discardableResult
    func addImage(_ png: Data, to easelID: UUID, caption: String = "", source: URL? = nil, center: CGPoint? = nil) -> EaselItem? {
        guard let image = NSImage(data: png), image.size.width > 0, image.size.height > 0 else { return nil }
        let hash: String
        do {
            hash = try images.save(png)
        } catch {
            Self.logger.error("Saving an image failed: \(error)")
            return nil
        }
        let width = min(Double(image.size.width), Self.maxImageWidth)
        let height = width * Double(image.size.height / image.size.width)
        let origin = center.map { CGPoint(x: $0.x - width / 2, y: $0.y - height / 2) } ?? nextFreeSpot(in: easelID)
        return add(EaselItem(
            easelID: easelID, kind: .image,
            x: max(0, origin.x), y: max(0, origin.y), width: width, height: height,
            text: caption, url: source, imageHash: hash
        ))
    }

    @discardableResult
    func addLink(_ url: URL, title: String, to easelID: UUID, center: CGPoint? = nil) -> EaselItem {
        let origin = center.map { CGPoint(x: $0.x - 130, y: $0.y - 32) } ?? nextFreeSpot(in: easelID)
        return add(EaselItem(
            easelID: easelID, kind: .link,
            x: max(0, origin.x), y: max(0, origin.y), width: 260, height: 64,
            text: title, url: url
        ))
    }

    @discardableResult
    func addText(_ text: String, to easelID: UUID, center: CGPoint? = nil, color: String? = nil) -> EaselItem {
        let origin = center.map { CGPoint(x: $0.x - 110, y: $0.y - 20) } ?? nextFreeSpot(in: easelID)
        return add(EaselItem(
            easelID: easelID, kind: .text,
            x: max(0, origin.x), y: max(0, origin.y), width: 220, height: 40, text: text, color: color
        ))
    }

    /// A circle, rectangle, arrow or stroke drawn on the canvas.
    @discardableResult
    func addShape(_ kind: EaselItemKind, frame: CGRect, points: [EaselPoint] = [], color: String? = nil, to easelID: UUID) -> EaselItem {
        add(EaselItem(
            easelID: easelID, kind: kind,
            x: max(0, frame.minX), y: max(0, frame.minY), width: frame.width, height: frame.height,
            points: points, color: color
        ))
    }

    /// Below the lowest item, so new things don't land on top of old ones.
    private func nextFreeSpot(in easelID: UUID) -> CGPoint {
        let bottom = items(in: easelID).map { $0.y + $0.height }.max() ?? 0
        return CGPoint(x: 40, y: bottom + 40)
    }

    func image(for hash: String) -> NSImage? {
        if let cached = imageCache.object(forKey: hash as NSString) { return cached }
        guard let data = images.data(for: hash), let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: hash as NSString)
        return image
    }

    // MARK: Sync

    /// Replaces everything with the synced state.
    func replaceAll(with newSnapshot: EaselSnapshot) {
        guard newSnapshot != snapshot else { return }
        let changedEasels = Set(snapshot.items.map(\.easelID)).union(newSnapshot.items.map(\.easelID))
        snapshot = newSnapshot
        persist { try $0.saveEasels(newSnapshot) }
        onChange?()
        changedEasels.forEach { onItemsChange?($0) }
    }

    /// An image arrived through sync; redraw Easels that show it.
    func imageArrived(_ hash: String) {
        for easel in Set(snapshot.items.filter { $0.imageHash == hash }.map(\.easelID)) {
            onItemsChange?(easel)
        }
    }

    private func persist(_ write: (AppDatabase) throws -> Void) {
        do {
            try write(database)
        } catch {
            Self.logger.error("Saving Easels failed: \(error)")
        }
    }
}
