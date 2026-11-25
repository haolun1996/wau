import Core
import Foundation
import Testing
@testable import Sync

// MARK: Fakes

/// A remote file store in memory, counting writes.
actor MemoryRemote: RemoteStore {
    var files: [String: Data] = [:]
    var writes = 0
    func read(_ name: String) async throws -> Data? { files[name] }
    func write(_ name: String, _ data: Data) async throws {
        files[name] = data
        writes += 1
    }
}

final class MemoryStateStore: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SyncState?
    func loadSyncState() throws -> SyncState? { lock.withLock { state } }
    func saveSyncState(_ state: SyncState?) throws { lock.withLock { self.state = state } }
}

/// Answers requests from a queue of canned responses and records them.
actor FakeTransport: HTTPTransport {
    var responses: [(Int, Data)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses.map { ($0.0, Data($0.1.utf8)) } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.isEmpty ? (500, Data()) : responses.removeFirst()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// A clock tests can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

let config = GoogleOAuthConfig(clientID: "123-abc.apps.googleusercontent.com")!

// MARK: OAuth

@Suite("Google OAuth")
struct GoogleOAuthTests {
    @Test func pkceMatchesTheRFCExample() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count == 43)
    }

    @Test func configNeedsAGoogleClientID() {
        #expect(GoogleOAuthConfig(clientID: nil) == nil)
        #expect(GoogleOAuthConfig(clientID: "$(WAU_GOOGLE_CLIENT_ID)") == nil) // unfilled build setting
        #expect(config.redirectScheme == "com.googleusercontent.apps.123-abc")
        #expect(config.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    @Test func authorizationURLCarriesPKCEAndScopes() throws {
        let url = GoogleOAuth.authorizationURL(config: config, pkce: PKCE(verifier: "v"), state: "s1")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == config.clientID)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == PKCE(verifier: "v").challenge)
        #expect(query["scope"]?.contains("drive.appdata") == true)
        #expect(query["state"] == "s1")
    }

    @Test func callbackParsing() throws {
        let good = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=s1&code=4%2Fxyz")!
        #expect(try GoogleOAuth.authorizationCode(from: good, expectedState: "s1") == "4/xyz")
        #expect(throws: SyncError.self) {
            try GoogleOAuth.authorizationCode(from: good, expectedState: "other")
        }
        let denied = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?error=access_denied&state=s1")!
        #expect(throws: SyncError.signInFailed("access_denied")) {
            try GoogleOAuth.authorizationCode(from: denied, expectedState: "s1")
        }
    }

    @Test func tokenResponsesAndRefreshesKeepWhatTheyOmit() throws {
        // {"email":"kite@example.com"} in an unsigned JWT body.
        let idToken = "e30." + Data(#"{"email":"kite@example.com"}"#.utf8).base64URLEncoded + ".sig"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try GoogleOAuth.tokens(
            from: Data(#"{"access_token":"a1","expires_in":3600,"refresh_token":"r1","id_token":"\#(idToken)"}"#.utf8),
            now: now
        )
        #expect(first == GoogleTokens(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(3540), email: "kite@example.com"))

        let refreshed = try GoogleOAuth.tokens(from: Data(#"{"access_token":"a2","expires_in":3600}"#.utf8), previous: first, now: now)
        #expect(refreshed.refreshToken == "r1")
        #expect(refreshed.email == "kite@example.com")
        #expect(throws: SyncError.invalidResponse) { try GoogleOAuth.tokens(from: Data("nope".utf8)) }
    }

    @Test func formRequestsAreEncoded() throws {
        let request = GoogleOAuth.tokenRequest(code: "4/a b&c", pkce: PKCE(verifier: "v"), config: config)
        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        #expect(request.httpMethod == "POST")
        #expect(body.contains("code=4%2Fa%20b%26c"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=v"))
    }
}

// MARK: Drive

@Suite("Google Drive store")
struct GoogleDriveTests {
    func session(_ transport: FakeTransport, expired: Bool = false, clock: TestClock = TestClock()) -> GoogleSession {
        let tokens = GoogleTokens(accessToken: "old", refreshToken: "r", expiresAt: clock.now.addingTimeInterval(expired ? -1 : 3600), email: nil)
        return GoogleSession(config: config, tokens: tokens, transport: transport, now: { clock.now }, onTokensChanged: { _ in })
    }

    @Test func readFindsTheFileThenDownloadsIt() async throws {
        let transport = FakeTransport([(200, #"{"files":[{"id":"F1","name":"wau-sync.json"}]}"#), (200, "hello")])
        let store = GoogleDriveStore(session: session(transport), transport: transport)
        let data = try await store.read("wau-sync.json")
        #expect(data == Data("hello".utf8))
        let requests = await transport.requests
        #expect(requests[0].url?.query?.contains("spaces=appDataFolder") == true)
        #expect(requests[1].url?.absoluteString.hasSuffix("/files/F1?alt=media") == true)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer old" })
    }

    @Test func missingFileReadsAsNilAndWriteCreatesIt() async throws {
        let transport = FakeTransport([(200, #"{"files":[]}"#), (200, #"{"files":[]}"#), (200, #"{"id":"NEW"}"#), (200, "{}")])
        let store = GoogleDriveStore(session: session(transport), transport: transport)
        #expect(try await store.read("wau-sync.json") == nil)
        try await store.write("wau-sync.json", Data("v1".utf8)) // creates (lists again: cached nil isn't trusted)
        try await store.write("wau-sync.json", Data("v2".utf8)) // updates the created file by ID
        let requests = await transport.requests
        #expect(requests[2].httpMethod == "POST")
        #expect(requests[2].url?.query == "uploadType=multipart")
        let body = String(decoding: requests[2].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""parents":["appDataFolder"]"#))
        #expect(requests[3].httpMethod == "PATCH")
        #expect(requests[3].url?.absoluteString.contains("/files/NEW?uploadType=media") == true)
    }

    @Test func expiredTokenIsRefreshedFirst() async throws {
        let transport = FakeTransport([(200, #"{"access_token":"fresh","expires_in":3600}"#), (200, #"{"files":[]}"#)])
        let store = GoogleDriveStore(session: session(transport, expired: true), transport: transport)
        _ = try await store.read("x.json")
        let requests = await transport.requests
        #expect(requests[0].url == GoogleOAuth.tokenEndpoint)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func unauthorizedRetriesOnceAfterRefreshing() async throws {
        let transport = FakeTransport([(401, "expired"), (200, #"{"access_token":"fresh","expires_in":3600}"#), (200, #"{"files":[]}"#)])
        let store = GoogleDriveStore(session: session(transport), transport: transport)
        #expect(try await store.read("x.json") == nil)
        #expect(await transport.requests.count == 3)
    }

    @Test func revokedAccessMeansSignedOut() async throws {
        let transport = FakeTransport([(400, #"{"error":"invalid_grant"}"#)])
        let store = GoogleDriveStore(session: session(transport, expired: true), transport: transport)
        await #expect(throws: SyncError.notSignedIn) { _ = try await store.read("x.json") }
    }
}

// MARK: Engine

@Suite("SyncEngine")
struct SyncEngineTests {
    @Test func firstSyncUploadsAndCommitRemembersIt() async throws {
        let remote = MemoryRemote(), store = MemoryStateStore(), clock = TestClock()
        let engine = SyncEngine(remote: remote, store: store, now: { clock.now })
        #expect(try await engine.hasSyncedBefore() == false)
        #expect(try await engine.remoteHasData() == false)

        let current: [String: SyncFields] = ["space:1": ["name": "Work"]]
        let result = try await engine.sync(current: current)
        #expect(result.uploaded)
        #expect(result.liveFields == current)
        try await engine.commit(result)
        #expect(try await engine.hasSyncedBefore())

        // Nothing changed: nothing to upload.
        clock.advance(60)
        let again = try await engine.sync(current: current)
        #expect(!again.uploaded)
        #expect(await remote.writes == 1)
    }

    @Test func twoMacsConvergeThroughDrive() async throws {
        let remote = MemoryRemote(), clock = TestClock()
        let mac1 = SyncEngine(remote: remote, store: MemoryStateStore(), now: { clock.now })
        let mac2 = SyncEngine(remote: remote, store: MemoryStateStore(), now: { clock.now })

        var state1: [String: SyncFields] = ["space:a": ["name": "Work"], "space:b": ["name": "Home"]]
        try await mac1.commit(try await mac1.sync(current: state1))

        // The second Mac starts with its own Space and merges.
        let first2 = try await mac2.sync(current: ["space:c": ["name": "Kopi"]], firstSync: .merge)
        var state2 = first2.liveFields
        try await mac2.commit(first2)
        #expect(Set(state2.keys) == ["space:a", "space:b", "space:c"])

        // Independent edits a minute later.
        clock.advance(60)
        state1["space:a"] = ["name": "Kerja"]
        state2["space:b"] = nil
        let r1 = try await mac1.sync(current: state1); state1 = r1.liveFields; try await mac1.commit(r1)
        let r2 = try await mac2.sync(current: state2); state2 = r2.liveFields; try await mac2.commit(r2)
        let r1b = try await mac1.sync(current: state1); state1 = r1b.liveFields; try await mac1.commit(r1b)

        #expect(state1 == state2)
        #expect(state1 == ["space:a": ["name": "Kerja"], "space:c": ["name": "Kopi"]])
    }

    @Test func replaceLocalAdoptsTheRemoteCopy() async throws {
        let remote = MemoryRemote(), clock = TestClock()
        let mac1 = SyncEngine(remote: remote, store: MemoryStateStore(), now: { clock.now })
        try await mac1.commit(try await mac1.sync(current: ["space:a": ["name": "Work"]]))

        let mac2 = SyncEngine(remote: remote, store: MemoryStateStore(), now: { clock.now })
        #expect(try await mac2.remoteHasData())
        let result = try await mac2.sync(current: ["space:local": ["name": "Personal"]], firstSync: .replaceLocal)
        #expect(result.liveFields == ["space:a": ["name": "Work"]])
        #expect(!result.uploaded) // nothing new to send
    }

    @Test func uncommittedResultsAreRecomputedNextTime() async throws {
        let remote = MemoryRemote(), store = MemoryStateStore(), clock = TestClock()
        let engine = SyncEngine(remote: remote, store: store, now: { clock.now })
        _ = try await engine.sync(current: ["space:a": ["name": "Work"]]) // the app couldn't apply it
        #expect(try await engine.hasSyncedBefore() == false)
        let retry = try await engine.sync(current: ["space:a": ["name": "Work"], "space:b": ["name": "New"]])
        #expect(Set(retry.liveFields.keys) == ["space:a", "space:b"])
    }
}

@Suite("Image sync")
struct BlobSyncTests {
    final class Images: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data]
        init(_ files: [String: Data] = [:]) { self.files = files }
        func data(_ hash: String) -> Data? { lock.withLock { files[hash] } }
        func store(_ hash: String, _ data: Data) { lock.withLock { files[hash] = data } }
    }

    @Test func imagesUploadOnceAndDownloadWhereMissing() async throws {
        let remote = MemoryRemote()
        let mac1Images = Images(["aa11": Data("picture".utf8)])
        let mac1 = SyncEngine(remote: remote, store: MemoryStateStore())
        try await mac1.syncBlobs(needed: ["aa11"], localData: { mac1Images.data($0) }, storeDownloaded: { mac1Images.store($0, $1) })
        try await mac1.syncBlobs(needed: ["aa11"], localData: { mac1Images.data($0) }, storeDownloaded: { mac1Images.store($0, $1) })
        #expect(await remote.writes == 1)
        #expect(await remote.files["img-aa11.png"] == Data("picture".utf8))

        let mac2Images = Images()
        let mac2 = SyncEngine(remote: remote, store: MemoryStateStore())
        try await mac2.syncBlobs(needed: ["aa11", "ff99"], localData: { mac2Images.data($0) }, storeDownloaded: { mac2Images.store($0, $1) })
        #expect(mac2Images.data("aa11") == Data("picture".utf8))
        #expect(mac2Images.data("ff99") == nil) // not uploaded anywhere yet: tried again next sync
        #expect(await remote.writes == 1) // downloading doesn't upload it again
    }

    @Test func olderSavedStatesStillDecode() throws {
        let old = #"{"document":{"version":1,"entries":{}},"baseline":{},"deviceID":"D"}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(old.utf8))
        #expect(state.uploadedBlobs.isEmpty)
        #expect(state.deviceID == "D")
    }
}
