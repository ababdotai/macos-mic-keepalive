import Foundation

/// User intent survives temporary hardware loss; actual capture state does not.
struct KeepAliveIntent {
    enum Readiness: Equatable { case stopped, sleeping, missingDevice, needsPermission, ready(String) }
    var selectedID: String?
    var requested = false
    var sleeping = false

    init(selectedID: String? = nil, restoreOnLaunch: Bool = false, wasRequested: Bool = false) {
        self.selectedID = selectedID
        requested = restoreOnLaunch && wasRequested && selectedID != nil
    }
    /// Follow explicit route changes while connected. A hardware-loss fallback must
    /// not activate a different microphone; keep waiting for the original device.
    mutating func followSystemInput(_ current: String?, previous: String?, availableIDs: Set<String>) {
        guard !sleeping, let current, availableIDs.contains(current) else { return }
        if !requested || (current != previous && selectedID.map(availableIDs.contains) == true) {
            selectedID = current
        }
    }
    func readiness(availableIDs: Set<String>, authorized: Bool) -> Readiness {
        guard requested else { return .stopped }
        guard !sleeping else { return .sleeping }
        guard authorized else { return .needsPermission }
        guard let id = selectedID, availableIDs.contains(id) else { return .missingDevice }
        return .ready(id)
    }
}

/// Invalidates work queued before Stop, sleep, disconnect, or another start attempt.
final class CaptureGeneration {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func advance() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1; return value
    }
    func contains(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == ticket
    }
}

func runRecoveryTests() {
    let mic = "bluetooth-mic-A", other = "usb-mic-B"
    var intent = KeepAliveIntent(selectedID: mic)
    func readiness(_ ids: Set<String> = ["bluetooth-mic-A"], authorized: Bool = true) -> KeepAliveIntent.Readiness {
        intent.readiness(availableIDs: ids, authorized: authorized)
    }
    assert(readiness() == .stopped)
    intent.requested = true
    assert(readiness() == .ready(mic))
    intent.sleeping = true
    assert(readiness() == .sleeping)
    intent.sleeping = false
    assert(readiness() == .ready(mic))
    assert(readiness([other]) == .missingDevice) // Do not capture a fallback after disconnect.
    assert(readiness([]) == .missingDevice)
    assert(readiness([other, mic]) == .ready(mic))
    intent.sleeping = true
    intent.requested = false // Manual stop during suspension cancels all recovery.
    intent.sleeping = false
    assert(readiness() == .stopped)
    intent.requested = true
    assert(readiness(authorized: false) == .needsPermission)
    assert(readiness() == .ready(mic))
    for restore in [false, true] {
        for previous in [false, true] {
            let launched = KeepAliveIntent(selectedID: mic, restoreOnLaunch: restore, wasRequested: previous)
            assert(launched.requested == (restore && previous))
        }
    }
    assert(!KeepAliveIntent(restoreOnLaunch: true, wasRequested: true).requested)
    var routing = KeepAliveIntent(selectedID: mic)
    routing.followSystemInput(other, previous: nil, availableIDs: [mic, other])
    assert(routing.selectedID == other) // Stopped selection reflects the system.
    routing.requested = true
    routing.followSystemInput(mic, previous: other, availableIDs: [mic, other])
    assert(routing.selectedID == mic) // Live external route change.
    routing.followSystemInput(other, previous: mic, availableIDs: [other])
    assert(routing.selectedID == mic) // Disconnect fallback is not captured.
    routing.followSystemInput(other, previous: other, availableIDs: [mic, other])
    assert(routing.selectedID == mic) // Reconnect preserves the waiting target.
    routing.sleeping = true
    routing.followSystemInput(other, previous: mic, availableIDs: [mic, other])
    assert(routing.selectedID == mic)
    print("PASS: system route sync, live switching intent, disconnect fallback and sleep protection")
    let gate = CaptureGeneration()
    let starting = gate.advance()
    let stopped = gate.advance()
    assert(!gate.contains(starting) && gate.contains(stopped))
    let restarting = gate.advance()
    assert(!gate.contains(stopped) && gate.contains(restarting))
    print("PASS: sleep/wake, same-device reconnect, manual-stop cancellation, permission loss, launch opt-in, stale-work cancellation")
}

/// Successful manual switches, persisted by stable device UID rather than name.
final class DeviceUsage {
    private let defaults: UserDefaults
    private var counts: [String: Int]
    private var lastUsed: [String: Double]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        counts = defaults.dictionary(forKey: "deviceUsageCounts") as? [String: Int] ?? [:]
        lastUsed = defaults.dictionary(forKey: "deviceUsageDates") as? [String: Double] ?? [:]
    }
    func record(_ id: String, at date: Date = Date()) {
        counts[id, default: 0] += 1
        lastUsed[id] = date.timeIntervalSince1970
        defaults.set(counts, forKey: "deviceUsageCounts")
        defaults.set(lastUsed, forKey: "deviceUsageDates")
    }
    func precedes(_ lhs: String, name left: String, _ rhs: String, name right: String) -> Bool {
        if counts[lhs, default: 0] != counts[rhs, default: 0] {
            return counts[lhs, default: 0] > counts[rhs, default: 0]
        }
        if lastUsed[lhs, default: 0] != lastUsed[rhs, default: 0] {
            return lastUsed[lhs, default: 0] > lastUsed[rhs, default: 0]
        }
        let comparison = left.localizedStandardCompare(right)
        return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
    }
}
func runDeviceUsageTests() {
    let suite = "MicKeepAlive-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = DeviceUsage(defaults: defaults)
    usage.record("A", at: Date(timeIntervalSince1970: 1))
    usage.record("A", at: Date(timeIntervalSince1970: 2))
    usage.record("B", at: Date(timeIntervalSince1970: 3))
    assert(usage.precedes("A", name: "Z", "B", name: "A"))
    usage.record("B", at: Date(timeIntervalSince1970: 4))
    assert(usage.precedes("B", name: "Z", "A", name: "A"))
    let restored = DeviceUsage(defaults: defaults)
    assert(restored.precedes("B", name: "Z", "A", name: "A"))
    assert(restored.precedes("C", name: "Alpha", "D", name: "Beta"))
    assert(restored.precedes("C", name: "Same", "D", name: "Same"))
    assert(!restored.precedes("C", name: "Same", "C", name: "Same"))
    print("PASS: device frequency, recency tie-break, persistence, deterministic fallback")
}
