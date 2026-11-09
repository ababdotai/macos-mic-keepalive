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
    assert(readiness([other]) == .missingDevice) // Never follow the default input.
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
    let gate = CaptureGeneration()
    let starting = gate.advance()
    let stopped = gate.advance()
    assert(!gate.contains(starting) && gate.contains(stopped))
    let restarting = gate.advance()
    assert(!gate.contains(stopped) && gate.contains(restarting))
    print("PASS: sleep/wake, same-device reconnect, manual-stop cancellation, permission loss, launch opt-in, stale-work cancellation")
}
