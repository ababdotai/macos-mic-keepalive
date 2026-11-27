import AppKit
import Darwin

let args = CommandLine.arguments
guard args.count == 6, let oldPID = Int32(args[1]), oldPID > 1,
      UUID(uuidString: args[4]) != nil, ReleaseVersion(args[5]) != nil else { exit(2) }
let destination = URL(fileURLWithPath: args[2]).standardizedFileURL
let candidate = URL(fileURLWithPath: args[3]).standardizedFileURL
let token = args[4], expectedVersion = args[5]
let work = try UpdateFiles.directory(token: token)
let fm = FileManager.default
func waitUntil(_ timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < end
    return false
}
func openApp(updated: Bool) throws {
    var arguments = ["-n", destination.path]
    if updated { arguments += ["--args", "--updated", token] }
    try UpdateFiles.run("/usr/bin/open", arguments)
}
do {
    guard destination.pathExtension == "app", destination.resolvingSymlinksInPath().path == destination.path,
          candidate.path.hasPrefix(work.path + "/"),
          fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateFailure("Application is not writable") }
    let lockPath = destination.deletingLastPathComponent().appendingPathComponent(".KeepMicAlive-update.lock").path
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw UpdateFailure("Another update is running") }
    defer { close(descriptor) }
    _ = try UpdateFiles.version(of: destination)
    try UpdateFiles.verifyBundle(candidate, expectedVersion: expectedVersion)
    try Data(token.utf8).write(to: work.appendingPathComponent("ready"), options: .atomic)
    guard waitUntil(45, condition: { kill(oldPID, 0) != 0 && errno == ESRCH }) else { throw UpdateFailure("The old app did not quit") }
    try AppReplacement.replace(candidate: candidate, destination: destination) {
        try UpdateFiles.verifyBundle(destination, expectedVersion: expectedVersion)
        try openApp(updated: true)
        guard waitUntil(30, condition: { fm.fileExists(atPath: work.appendingPathComponent("launched").path) }) else {
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: UpdateFiles.bundleID)
                .filter { $0.bundleURL?.standardizedFileURL.path == destination.path && $0.processIdentifier != oldPID }
            for process in processes { process.terminate() }
            // These are only the new processes just launched by this update.
            for process in processes where !waitUntil(5, condition: { process.isTerminated }) { process.forceTerminate() }
            throw UpdateFailure("New application did not acknowledge startup")
        }
    }
    // Receipt remains after cleanup so the new app/user can inspect the result.
    try? Data("Updated to \(expectedVersion)\n".utf8).write(to: UpdateFiles.root.appendingPathComponent("last-update.txt"), options: .atomic)
    try? fm.removeItem(at: work)
} catch {
    try? Data(error.localizedDescription.utf8).write(to: UpdateFiles.root.appendingPathComponent("last-update-error.txt"), options: .atomic)
    // If replacement failed, AppReplacement has already restored the old bundle.
    if kill(oldPID, 0) != 0 { try? openApp(updated: false) }
    exit(1)
}
