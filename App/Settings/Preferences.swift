import Core
import Foundation

/// App-wide settings, stored in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var searchEngineID: String {
        didSet { defaults.set(searchEngineID, forKey: "searchEngine") }
    }

    /// Links opened from other apps go to Little Wau rather than a new tab.
    @Published var openLinksInLittleWau: Bool {
        didSet { defaults.set(openLinksInLittleWau, forKey: "openLinksInLittleWau") }
    }

    private init() {
        searchEngineID = defaults.string(forKey: "searchEngine") ?? SearchEngine.google.id
        openLinksInLittleWau = defaults.object(forKey: "openLinksInLittleWau") as? Bool ?? true
    }

    var searchEngine: SearchEngine {
        SearchEngine.engine(withID: searchEngineID) ?? .google
    }
}
