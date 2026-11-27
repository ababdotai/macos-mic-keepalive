import Foundation
import CryptoKit

struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum UpdateFiles {
    static let bundleID = "local.macos-mic-keepalive"
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID).appendingPathComponent("Updates")
    }
    static func directory(token: String) throws -> URL {
        guard UUID(uuidString: token) != nil else { throw UpdateFailure("Invalid update token") }
        return root.appendingPathComponent(token, isDirectory: true)
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateFailure("\(URL(fileURLWithPath: executable).lastPathComponent): \(output.prefix(400))")
        }
        return output
    }
    static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verifyChecksum(_ file: URL, manifest: Data) throws {
        guard manifest.count < 1_000_000, let text = String(data: manifest, encoding: .utf8) else { throw UpdateFailure("Invalid checksum file") }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[1] == file.lastPathComponent else { return nil }
            return String(parts[0]).lowercased()
        }
        guard matches.count == 1, matches[0].count == 64,
              matches[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              try checksum(file) == matches[0] else { throw UpdateFailure("Download checksum mismatch") }
    }
    /// This app's archives contain only ordinary files/directories, no frameworks
    /// or symbolic links. Reject path traversal, links and excessive expansion.
    static func validateArchiveListing(paths: String, details: String) throws {
        let entries = paths.split(separator: "\n", omittingEmptySubsequences: true)
        guard !entries.isEmpty, entries.count <= 2000 else { throw UpdateFailure("Invalid ZIP entries") }
        for entry in entries {
            let path = String(entry), parts = path.split(separator: "/")
            guard path.hasPrefix("KeepMicAlive.app/") || path.hasPrefix("__MACOSX/"),
                  !parts.contains(".."), !parts.contains("."), !path.contains("\\"), !path.contains("\r") else {
                throw UpdateFailure("Unsafe ZIP path")
            }
        }
        var total: Int64 = 0, count = 0
        for line in details.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let mode = parts.first, mode.count == 10 else { continue }
            guard mode.first == "-" || mode.first == "d", parts.count >= 9,
                  let bytes = Int64(parts[3]), bytes >= 0, bytes <= 256_000_000 else { throw UpdateFailure("Unsafe ZIP entry") }
            total += bytes; count += 1
        }
        guard count == entries.count, total <= 256_000_000 else { throw UpdateFailure("ZIP expansion exceeds limit") }
    }
    static func unpack(_ archive: URL, into directory: URL) throws -> URL {
        let paths = try run("/usr/bin/unzip", ["-Z", "-1", archive.path])
        let details = try run("/usr/bin/unzip", ["-Z", "-l", archive.path])
        try validateArchiveListing(paths: paths, details: details)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        return directory.appendingPathComponent("KeepMicAlive.app")
    }
    static func version(of app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleExecutable"] as? String == "KeepMicAlive",
              let version = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion(version) != nil else { throw UpdateFailure("Unexpected application identity") }
        if let minimum = info["LSMinimumSystemVersion"] as? String, let required = ReleaseVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!
            guard required <= current else { throw UpdateFailure("This release requires a newer macOS") }
        }
        return version
    }
    static func verifyBundle(_ app: URL, expectedVersion: String) throws {
        guard try version(of: app) == expectedVersion,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/KeepMicAlive").path) else {
            throw UpdateFailure("Downloaded application version does not match the release")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
}

/// One-use state transfer for an explicit app update only. Ordinary launches
/// retain their existing opt-in keep-alive and boost-off behavior.
struct UpdateResume: Codable {
    let requested: Bool
    let enhancement: Bool
    let gain: Float
    let noiseReduction: Bool
    let voiceClarity: Bool
    let selectedID: String?
    let selectedName: String?

    func save(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("resume.json"), options: .atomic)
    }
    static func consume(token: String) throws -> Self {
        let directory = try UpdateFiles.directory(token: token)
        let source = directory.appendingPathComponent("resume.json")
        let data = try Data(contentsOf: source)
        guard data.count < 8192 else { throw UpdateFailure("Invalid resume state") }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard [Float(6), 12, 18].contains(state.gain), !state.enhancement || state.requested else { throw UpdateFailure("Invalid capture state") }
        try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent("resume-used.json"))
        return state
    }
    static var launchToken: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--updated"), index + 1 < args.count, UUID(uuidString: args[index+1]) != nil else { return nil }
        return args[index+1]
    }
    static func acknowledge(token: String) throws {
        let directory = try UpdateFiles.directory(token: token)
        try Data(token.utf8).write(to: directory.appendingPathComponent("launched"), options: .atomic)
    }
}

enum AppReplacement {
    /// Keep the old bundle until the replacement has actually launched. Any
    /// failed copy, rename or launch restores the original at the same path.
    static func replace(candidate: URL, destination: URL, launch: () throws -> Void) throws {
        let fm = FileManager.default, parent = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".KeepMicAlive-install-\(token).app")
        let backup = parent.appendingPathComponent(".KeepMicAlive-previous-\(token).app")
        try fm.copyItem(at: candidate, to: staged)
        defer { try? fm.removeItem(at: staged) }
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: staged, to: destination)
            try launch()
        } catch {
            // The launch closure must stop a failed new process before throwing.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: backup, to: destination)
            throw error
        }
        try? fm.removeItem(at: backup)
    }
}

/// Stable numeric versions only. Prereleases must never replace a stable install.
struct ReleaseVersion: Comparable {
    let components: [Int]
    init?(_ value: String) {
        let tag = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = tag.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  piece.count == 1 || piece.first != "0", let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}
