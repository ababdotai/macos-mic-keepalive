import AppKit

enum InstallationState: Equatable {
    case idle, downloading(Int), verifying, restarting, failed(String)
    var busy: Bool {
        switch self { case .downloading, .verifying, .restarting: return true; default: return false }
    }
}

struct PreparedUpdate {
    let work: URL
    let application: URL
    let helper: URL
    let version: String
}

/// Download callbacks run on main; checksum, extraction and signature checks run
/// on a worker queue. Capture continues until the helper is ready to take over.
final class UpdateInstaller: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private var task: URLSessionDownloadTask?
    private var work: URL?
    private(set) var state = InstallationState.idle
    var onChange: ((InstallationState) -> Void)?
    var onPrepared: ((PreparedUpdate) -> Void)?
    private var release: ReleaseUpdate?

    private func set(_ state: InstallationState) { self.state = state; onChange?(state) }
    func fail(_ error: Error) {
        task?.cancel(); task = nil
        set(.failed(L("update_install_failed", error.localizedDescription)))
    }
    func begin(_ release: ReleaseUpdate) {
        guard !state.busy else { return }
        do {
            let app = Bundle.main.bundleURL
            guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
                  FileManager.default.isWritableFile(atPath: app.path), !app.path.contains("/AppTranslocation/") else {
                throw UpdateFailure(L("update_move_app"))
            }
            guard release.downloadURL.pathExtension == "zip" else {
                // Older releases without a ZIP retain the ordinary DMG flow.
                NSWorkspace.shared.open(release.downloadURL)
                throw UpdateFailure(L("update_manual_installer"))
            }
            if let work { try? FileManager.default.removeItem(at: work) }
            let work = try UpdateFiles.directory(token: UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            self.work = work; self.release = release
            try? FileManager.default.removeItem(at: UpdateFiles.root.appendingPathComponent("last-update-error.txt"))
            set(.downloading(0))
            task = session.downloadTask(with: release.downloadURL)
            task?.resume()
        } catch { fail(error) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask === task else { return }
        if totalBytesWritten > 100_000_000 || totalBytesExpectedToWrite > 100_000_000 { fail(UpdateFailure("Installer exceeds size limit")); return }
        let progress = totalBytesExpectedToWrite > 0 ? min(99, Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)) : 0
        if state != .downloading(progress) { set(.downloading(progress)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, let error else { return }
        fail(error)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask === task, let work, let release else { return }
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure(L("update_network_error")) }
            let archive = work.appendingPathComponent(release.downloadURL.lastPathComponent)
            try FileManager.default.moveItem(at: location, to: archive) // Must move before delegate returns.
            task = nil; set(.verifying)
            let checksumURL = release.downloadURL.deletingLastPathComponent().appendingPathComponent("SHA256SUMS.txt")
            session.dataTask(with: checksumURL) { [weak self] data, response, error in
                guard let self else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data else {
                    DispatchQueue.main.async { if self.work == work && self.state.busy { self.fail(error ?? UpdateFailure("Checksum download failed")) } }
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try UpdateFiles.verifyChecksum(archive, manifest: data)
                        let application = try UpdateFiles.unpack(archive, into: work.appendingPathComponent("unpacked"))
                        try UpdateFiles.verifyBundle(application, expectedVersion: release.version)
                        let helper = work.appendingPathComponent("KeepMicAliveUpdater")
                        let sourceHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeepMicAliveUpdater")
                        try FileManager.default.copyItem(at: sourceHelper, to: helper)
                        try UpdateFiles.run("/usr/bin/codesign", ["--verify", "--strict", helper.path])
                        let prepared = PreparedUpdate(work: work, application: application, helper: helper, version: release.version)
                        DispatchQueue.main.async {
                            guard self.work == work && self.state.busy else { return }
                            self.set(.restarting); self.onPrepared?(prepared)
                        }
                    } catch {
                        DispatchQueue.main.async { if self.work == work && self.state.busy { self.fail(error) } }
                    }
                }
            }.resume()
        } catch { fail(error) }
    }
    func launch(_ prepared: PreparedUpdate, resume: UpdateResume, ready: @escaping () -> Void) throws {
        try resume.save(to: prepared.work)
        let process = Process()
        process.executableURL = prepared.helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.standardizedFileURL.path,
                             prepared.application.path, prepared.work.lastPathComponent, prepared.version]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        // Do not quit until the helper has completed its own preflight.
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(15)
            let signal = prepared.work.appendingPathComponent("ready")
            while process.isRunning && Date() < deadline && !FileManager.default.fileExists(atPath: signal.path) {
                Thread.sleep(forTimeInterval: 0.1)
            }
            let isReady = FileManager.default.fileExists(atPath: signal.path) && process.isRunning
            DispatchQueue.main.async {
                if isReady { ready() }
                else {
                    if process.isRunning { process.terminate() }
                    let detail = (try? String(contentsOf: UpdateFiles.root.appendingPathComponent("last-update-error.txt"), encoding: .utf8)) ?? "Updater did not become ready"
                    self.fail(UpdateFailure(detail))
                }
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        session.invalidateAndCancel()
    }
}
