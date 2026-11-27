import Foundation

struct ReleaseUpdate: Equatable {
    let version: String
    let downloadURL: URL
}

struct UpdateState: Equatable {
    var checking = false
    var available: ReleaseUpdate?
    var checked = false
    var error: String?
}

enum ReleaseFeed {
    static let endpoint = URL(string: "https://api.github.com/repos/ababdotai/KeepMicAlive/releases/latest")!
    static let latestPage = URL(string: "https://github.com/ababdotai/KeepMicAlive/releases/latest")!
    static let downloadsPrefix = "/ababdotai/KeepMicAlive/releases/download/"
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let state: String
        let size: Int
    }
    enum Failure: Error { case invalidResponse, missingInstaller }

    static func update(from data: Data, installed: String) throws -> ReleaseUpdate? {
        guard data.count < 2_000_000, let current = ReleaseVersion(installed) else { throw Failure.invalidResponse }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard let latest = ReleaseVersion(release.tag_name) else { throw Failure.invalidResponse }
        guard latest > current else { return nil }
        // Use a version-pinned asset, not /latest/download (which can change
        // between the check and the click). Never open arbitrary URLs from JSON.
        for name in ["KeepMicAlive-universal.zip", "KeepMicAlive-universal.dmg"] {
            if let asset = release.assets.first(where: {
                $0.name == name && $0.state == "uploaded" && $0.size > 0 &&
                isTrustedDownload($0.browser_download_url, tag: release.tag_name, filename: name)
            }) {
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                return ReleaseUpdate(version: version, downloadURL: asset.browser_download_url)
            }
        }
        throw Failure.missingInstaller
    }
    static func isTrustedDownload(_ url: URL, tag: String, filename: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.query == nil && url.fragment == nil &&
        url.path == downloadsPrefix + tag + "/" + filename
    }
    static func stableTag(from url: URL) -> String? {
        let prefix = "/ababdotai/KeepMicAlive/releases/tag/"
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, url.path.hasPrefix(prefix) else { return nil }
        let tag = String(url.path.dropFirst(prefix.count))
        return ReleaseVersion(tag) == nil ? nil : tag
    }
}

/// All state and timer mutations happen on the main thread. Requests are async
/// and independent of capture/sample queues; no credentials or audio are sent.
final class UpdateChecker {
    static let interval: TimeInterval = 8 * 60 * 60
    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    private let installed: String
    private let session: URLSession
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private var automatic = false
    private var generation = 0
    private(set) var lastAttempt: Date?
    private(set) var state = UpdateState()
    var onChange: ((UpdateState) -> Void)?

    init(installed: String = UpdateChecker.installedVersion, session: URLSession? = nil) {
        self.installed = installed
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }
    func start() {
        automatic = true
        check()
    }
    private func scheduleNextCheck() {
        guard automatic else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: false) { [weak self] _ in self?.check() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func checkIfDue(at date: Date = Date()) {
        guard let lastAttempt else { check(at: date); return }
        let elapsed = date.timeIntervalSince(lastAttempt)
        if elapsed >= Self.interval || elapsed < 0 { check(at: date) }
    }
    func check(at date: Date = Date()) {
        guard task == nil else { return }
        lastAttempt = date
        scheduleNextCheck()
        generation += 1
        guard ReleaseVersion(installed) != nil else {
            state.error = L("update_version_unknown"); onChange?(state); return
        }
        state.checking = true; state.error = nil; onChange?(state)
        var request = request(for: ReleaseFeed.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        fetch(request) { [weak self] data, response, error in
            guard let self else { return }
            if error != nil { self.finish(error: L("update_network_error")); return }
            guard let http = response as? HTTPURLResponse else { self.finish(error: L("update_invalid_response")); return }
            switch http.statusCode {
            case 200:
                do { self.finish(available: try ReleaseFeed.update(from: data ?? Data(), installed: self.installed)) }
                catch ReleaseFeed.Failure.missingInstaller { self.finish(error: L("update_missing_installer")) }
                catch { self.finish(error: L("update_invalid_response")) }
            case 403, 429:
                // Public API quotas are shared by IP. The ordinary latest-release
                // page works without an API token; HEAD follows its stable tag redirect.
                self.checkLatestPage()
            case 404: self.finish(error: L("update_no_release"))
            default: self.finish(error: L("update_network_error"))
            }
        }
    }
    private func request(for url: URL, head: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = head ? "HEAD" : "GET"
        request.setValue("KeepMicAlive/\(installed)", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func fetch(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        let ticket = generation
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.task != nil, self.generation == ticket else { return }
                self.task = nil
                completion(data, response, error)
            }
        }
        task?.resume()
    }
    private func checkLatestPage() {
        fetch(request(for: ReleaseFeed.latestPage, head: true)) { [weak self] _, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let url = http.url, let tag = ReleaseFeed.stableTag(from: url),
                  let version = ReleaseVersion(tag), let current = ReleaseVersion(self.installed) else {
                self.finish(error: L("update_rate_limited")); return
            }
            guard version > current else { self.finish(); return }
            self.checkInstaller(tag: tag, names: ["KeepMicAlive-universal.zip", "KeepMicAlive-universal.dmg"])
        }
    }
    private func checkInstaller(tag: String, names: [String]) {
        guard let name = names.first else { finish(error: L("update_missing_installer")); return }
        let url = URL(string: "https://github.com" + ReleaseFeed.downloadsPrefix + tag + "/" + name)!
        fetch(request(for: url, head: true)) { [weak self] _, response, error in
            guard let self else { return }
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                self.finish(available: ReleaseUpdate(version: version, downloadURL: url))
            } else { self.checkInstaller(tag: tag, names: Array(names.dropFirst())) }
        }
    }
    private func finish(available: ReleaseUpdate? = nil, error: String? = nil) {
        state.checking = false; state.error = error
        // A transient failure must not hide a previously found update.
        if error == nil { state.available = available; state.checked = true }
        onChange?(state)
    }
    func stop() {
        automatic = false; generation += 1
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        state.checking = false
    }
    deinit { timer?.invalidate(); task?.cancel() }
}
