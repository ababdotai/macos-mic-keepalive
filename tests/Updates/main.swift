import Foundation

func fixture(tag: String = "v1.6.0", draft: Bool = false, prerelease: Bool = false,
             filename: String = "KeepMicAlive-universal.dmg", assetURL: String? = nil, uploaded: Bool = true) -> Data {
    let url = assetURL ?? "https://github.com/ababdotai/KeepMicAlive/releases/download/\(tag)/\(filename)"
    return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease,
        "assets": [["name": filename, "browser_download_url": url, "state": uploaded ? "uploaded" : "new", "size": 1234]]])
}
func fails(_ data: Data) -> Bool {
    do { _ = try ReleaseFeed.update(from: data, installed: "1.5.1"); return false } catch { return true }
}
assert(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!)
assert(ReleaseVersion("v2.0")! == ReleaseVersion("2.0.0")!)
for invalid in ["", "01.2.3", "1..2", "1.2.3.4", "1.6.0-beta", "1.6.0+build", "1.2.-1", "1.2.a", "1.2.999999999999999999999999"] {
    assert(ReleaseVersion(invalid) == nil)
}
let release = try! ReleaseFeed.update(from: fixture(), installed: "1.5.1")!
assert(release.version == "1.6.0" && release.downloadURL.lastPathComponent.hasSuffix(".dmg"))
assert(try! ReleaseFeed.update(from: fixture(tag: "v1.5.1"), installed: "1.5.1") == nil)
assert(try! ReleaseFeed.update(from: fixture(tag: "v1.4.0"), installed: "1.5.1") == nil)
assert(try! ReleaseFeed.update(from: fixture(draft: true), installed: "1.5.1") == nil)
assert(try! ReleaseFeed.update(from: fixture(prerelease: true), installed: "1.5.1") == nil)
assert(try! ReleaseFeed.update(from: fixture(filename: "KeepMicAlive-universal.zip"), installed: "1.5.1")!.downloadURL.pathExtension == "zip")
assert(fails(fixture(uploaded: false)))
assert(fails(Data("broken JSON".utf8)))
for url in ["https://evil.example/app.dmg", "http://github.com/ababdotai/KeepMicAlive/releases/download/v1.6.0/KeepMicAlive-universal.dmg",
            "https://github.com/other/KeepMicAlive/releases/download/v1.6.0/KeepMicAlive-universal.dmg",
            "https://github.com/ababdotai/KeepMicAlive/releases/download/v1.5.0/KeepMicAlive-universal.dmg",
            "https://user@github.com/ababdotai/KeepMicAlive/releases/download/v1.6.0/KeepMicAlive-universal.dmg"] {
    assert(fails(fixture(assetURL: url)))
}
assert(ReleaseFeed.stableTag(from: URL(string: "https://github.com/ababdotai/KeepMicAlive/releases/tag/v1.6.0")!) == "v1.6.0")
assert(ReleaseFeed.stableTag(from: URL(string: "https://github.com/other/KeepMicAlive/releases/tag/v1.6.0")!) == nil)
assert(ReleaseFeed.stableTag(from: URL(string: "https://github.com/ababdotai/KeepMicAlive/releases/tag/v1.6.0-rc.1")!) == nil)

/// URLProtocol fixtures exercise the real asynchronous request/state path, with
/// no network access or credentials and no installation or browser side effects.
final class MockProtocol: URLProtocol {
    struct Reply { var code = 200; var data = Data(); var url: URL?; var failure: Error? }
    static let lock = NSLock()
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static func enqueue(_ replies: [Reply]) { lock.lock(); self.replies = replies; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        precondition(!Self.replies.isEmpty, "Unexpected request")
        let reply = Self.replies.removeFirst()
        Self.lock.unlock()
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.code, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockProtocol.self]
let session = URLSession(configuration: config)
let checker = UpdateChecker(installed: "1.5.1", session: session)
var completionCount = 0
checker.onChange = { state in
    assert(Thread.isMainThread)
    if !state.checking { completionCount += 1 }
}
func waitForResult() {
    let deadline = Date().addingTimeInterval(3)
    while checker.state.checking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    assert(!checker.state.checking, "Update check did not finish")
}
let start = Date(timeIntervalSince1970: 100_000)
MockProtocol.enqueue([.init(data: fixture())])
checker.check(at: start)
checker.check(at: start) // A second click must not create a second request.
waitForResult()
assert(MockProtocol.count == 1 && completionCount == 1 && checker.state.available == release)
checker.checkIfDue(at: start.addingTimeInterval(UpdateChecker.interval - 1))
assert(!checker.state.checking && MockProtocol.count == 1)
MockProtocol.enqueue([.init(failure: URLError(.notConnectedToInternet))])
checker.checkIfDue(at: start.addingTimeInterval(UpdateChecker.interval))
waitForResult()
assert(MockProtocol.count == 2 && checker.state.available == release && checker.state.error != nil)

MockProtocol.enqueue([.init(data: fixture(tag: "v1.5.1"))])
checker.check(); waitForResult()
assert(checker.state.checked && checker.state.available == nil && checker.state.error == nil)
MockProtocol.enqueue([.init(code: 200, data: Data("invalid".utf8))])
checker.check(); waitForResult()
assert(checker.state.error != nil && checker.state.available == nil)
MockProtocol.enqueue([.init(code: 404)])
checker.check(); waitForResult()
assert(checker.state.error == L("update_no_release"))

// An API quota failure can use GitHub's stable-page redirect and HEAD the asset.
let page = URL(string: "https://github.com/ababdotai/KeepMicAlive/releases/tag/v1.6.0")!
MockProtocol.enqueue([.init(code: 403), .init(url: page), .init(code: 404), .init()])
checker.check(); waitForResult()
assert(checker.state.available?.downloadURL.pathExtension == "dmg" && checker.state.error == nil)
assert(MockProtocol.requests.suffix(3).allSatisfy { $0.httpMethod == "HEAD" })
MockProtocol.enqueue([.init(code: 429), .init(url: URL(string: "https://github.com/ababdotai/KeepMicAlive/releases/tag/v1.5.1")!)])
checker.check(); waitForResult()
assert(checker.state.available == nil && checker.state.error == nil)

// Cancelling invalidates late callbacks, including any future fallback requests.
MockProtocol.enqueue([.init(data: fixture())])
checker.check(); checker.stop()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
assert(!checker.state.checking && checker.state.available == nil)
assert(MockProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
session.invalidateAndCancel()
print("PASS: release versions, stable-only assets, trusted URLs, async checks, duplicate clicks, 8-hour cadence, offline retention, API fallback and cancellation")

// Explicit opt-in smoke check: metadata/HEAD only, never downloads an installer.
if CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--live-update") {
    let expectUpdate = CommandLine.arguments.contains("--live-update")
    let live = UpdateChecker(installed: expectUpdate ? "0.0.0" : "1.5.1")
    live.check()
    let deadline = Date().addingTimeInterval(45)
    while live.state.checking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    print("LIVE: checking=\(live.state.checking), checked=\(live.state.checked), available=\(live.state.available?.version ?? "none"), error=\(live.state.error ?? "none")")
    assert(live.state.checked && live.state.error == nil && !live.state.checking)
    if expectUpdate { assert(live.state.available != nil) }
    live.stop()
}
