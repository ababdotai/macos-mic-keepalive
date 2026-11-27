import Foundation

func rejects(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
}
let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("KeepMicAlive updater tests \(UUID().uuidString)")
try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
let archive = temporary.appendingPathComponent("KeepMicAlive-universal.zip")
try Data("abc".utf8).write(to: archive)
let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
try UpdateFiles.verifyChecksum(archive, manifest: Data("\(digest)  KeepMicAlive-universal.zip\n".utf8))
assert(rejects { try UpdateFiles.verifyChecksum(archive, manifest: Data("\(digest)  wrong.zip".utf8)) })
try Data("changed".utf8).write(to: archive)
assert(rejects { try UpdateFiles.verifyChecksum(archive, manifest: Data("\(digest)  KeepMicAlive-universal.zip".utf8)) })

let goodPaths = "KeepMicAlive.app/\nKeepMicAlive.app/Contents/file\n"
let goodDetails = "drwxr-xr-x  2.1 unx 0 bx 0 stor 26-Nov-27 12:00 KeepMicAlive.app/\n-rw-r--r--  2.1 unx 12 bx 12 stor 26-Nov-27 12:00 KeepMicAlive.app/Contents/file\n"
try UpdateFiles.validateArchiveListing(paths: goodPaths, details: goodDetails)
for path in ["/tmp/escape", "KeepMicAlive.app/../../escape", "Other.app/file", "KeepMicAlive.app/Contents/../file"] {
    assert(rejects { try UpdateFiles.validateArchiveListing(paths: path, details: goodDetails) })
}
assert(rejects { try UpdateFiles.validateArchiveListing(paths: goodPaths, details: goodDetails.replacingOccurrences(of: "-rw-r--r--", with: "lrwxrwxrwx")) })
assert(rejects { try UpdateFiles.validateArchiveListing(paths: goodPaths, details: goodDetails.replacingOccurrences(of: "unx 12", with: "unx 999999999")) })

let candidate = temporary.appendingPathComponent("new app's files.app")
let installed = temporary.appendingPathComponent("KeepMicAlive.app")
try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
try fm.createDirectory(at: installed, withIntermediateDirectories: false)
try Data("new".utf8).write(to: candidate.appendingPathComponent("version"))
try Data("old".utf8).write(to: installed.appendingPathComponent("version"))
assert(rejects {
    try AppReplacement.replace(candidate: candidate, destination: installed) {
        assert(try! String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")
        throw UpdateFailure("Simulated startup failure")
    }
})
assert(try! String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "old")
try AppReplacement.replace(candidate: candidate, destination: installed) {
    assert(try! String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")
}
assert(try! String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")
assert(try! fm.contentsOfDirectory(atPath: temporary.path).allSatisfy { !$0.hasPrefix(".KeepMicAlive-") })
assert(rejects { try AppReplacement.replace(candidate: temporary.appendingPathComponent("missing"), destination: installed) {} })
assert(try! String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")

let token = UUID().uuidString
let handoff = try UpdateFiles.directory(token: token)
try fm.createDirectory(at: handoff, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: handoff) }
let resume = UpdateResume(requested: true, enhancement: true, gain: 12, noiseReduction: true, voiceClarity: true, selectedID: "physical-mic", selectedName: "Test microphone")
try resume.save(to: handoff)
let restored = try UpdateResume.consume(token: token)
assert(restored.requested && restored.enhancement && restored.noiseReduction && restored.voiceClarity && restored.gain == 12 && restored.selectedID == "physical-mic")
assert(rejects { _ = try UpdateResume.consume(token: token) })
assert(rejects { _ = try UpdateFiles.directory(token: "../escape") })
try UpdateResume.acknowledge(token: token)
assert(try! String(contentsOf: handoff.appendingPathComponent("launched"), encoding: .utf8) == token)

// Validate/extract the real packaged layout if a previous release is available.
let previousArchive = URL(fileURLWithPath: "dist/KeepMicAlive-universal.zip")
if fm.fileExists(atPath: previousArchive.path) {
    let app = try UpdateFiles.unpack(previousArchive, into: temporary.appendingPathComponent("unpacked"))
    let version = try UpdateFiles.version(of: app)
    try UpdateFiles.verifyBundle(app, expectedVersion: version)
    assert(rejects { try UpdateFiles.verifyBundle(app, expectedVersion: "0.0.0") })
    try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/tampered.txt"))
    assert(rejects { try UpdateFiles.verifyBundle(app, expectedVersion: version) })
}
print("PASS: checksum/tamper rejection, safe ZIP paths, expansion limits, real bundle identity/signature, replacement rollback and one-use audio-state resume")
