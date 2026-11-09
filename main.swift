import AppKit
import AVFoundation
import ServiceManagement

// Buffers are discarded; retain only a timestamp and scalar meter value.
func normalizedLevel(_ decibels: Float) -> Double {
    guard decibels.isFinite else { return 0 }
    return min(1, max(0, (Double(decibels) + 60) / 60))
}
func meterImage(_ levels: [Double]) -> NSImage {
    let image = NSImage(size: NSSize(width: 36, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            mic.draw(in: NSRect(x: 0, y: 3, width: 10, height: 12))
        }
        for (index, level) in levels.suffix(5).enumerated() {
            let height = max(2, 16 * level)
            NSBezierPath(roundedRect: NSRect(x: 12 + Double(index) * 5, y: (18 - height) / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}
final class SampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var last: TimeInterval = 0
    private var level: Double = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let db = connection.audioChannels.map { $0.averagePowerLevel }.max() ?? -160
        lock.lock(); last = ProcessInfo.processInfo.systemUptime; level = normalizedLevel(db); lock.unlock()
    }
    func reset() { lock.lock(); last = 0; level = 0; lock.unlock() }
    func meter() -> Double {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - last < 0.5 ? level : 0
    }
    func recent() -> Bool {
        lock.lock(); let value = last; lock.unlock()
        return value > 0 && ProcessInfo.processInfo.systemUptime - value < 4
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var info: NSMenuItem!
    private var deviceInfo: NSMenuItem!
    private var toggle: NSMenuItem!
    private var retry: NSMenuItem!
    private var login: NSMenuItem!
    private var restore: NSMenuItem!
    private var loginApproval: NSMenuItem!
    private var deviceMenu: NSMenu!
    private var intent = KeepAliveIntent()
    private var available: [AVCaptureDevice] = []
    private var selectedName: String?
    private let session = AVCaptureSession()
    private let sink = SampleSink()
    private let captureQueue = DispatchQueue(label: "local.mic.keepalive.capture")
    private let sampleQueue = DispatchQueue(label: "local.mic.keepalive.discard")
    private let gate = CaptureGeneration()
    private var activeID: String?
    private var busy = false
    private var requestingPermission = false
    private var terminating = false
    private var startedAt: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var failures = 0
    private var lastError: String?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var levels = Array(repeating: 0.0, count: 5)
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var readiness: KeepAliveIntent.Readiness {
        intent.readiness(availableIDs: Set(available.map(\.uniqueID)), authorized: authorized)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        intent = KeepAliveIntent(selectedID: defaults.string(forKey: "selectedMicrophoneID"),
                                 restoreOnLaunch: defaults.bool(forKey: "restoreKeepAliveOnLaunch"),
                                 wasRequested: defaults.bool(forKey: "keepAliveRequested"))
        defaults.set(intent.requested, forKey: "keepAliveRequested")
        selectedName = defaults.string(forKey: "selectedMicrophoneName")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        deviceInfo = NSMenuItem(title: "", action: nil, keyEquivalent: ""); deviceInfo.isEnabled = false
        info = NSMenuItem(title: "", action: nil, keyEquivalent: ""); info.isEnabled = false
        menu.addItem(deviceInfo); menu.addItem(info); menu.addItem(.separator())
        func action(_ key: String, _ selector: Selector) -> NSMenuItem {
            let row = NSMenuItem(title: L(key), action: selector, keyEquivalent: "")
            row.target = self; menu.addItem(row); return row
        }
        toggle = action("start", #selector(toggleCapture))
        retry = action("retry_now", #selector(retryCapture))
        let devicesItem = NSMenuItem(title: L("choose"), action: nil, keyEquivalent: "")
        deviceMenu = NSMenu(); deviceMenu.autoenablesItems = false
        devicesItem.submenu = deviceMenu; menu.addItem(devicesItem)
        menu.addItem(.separator())
        login = action("launch_at_login", #selector(toggleLogin))
        loginApproval = action("login_approval", #selector(openLoginSettings))
        restore = action("restore_on_launch", #selector(toggleRestore))
        menu.addItem(.separator())
        _ = action("help", #selector(showHelp))
        let quit = action("quit", #selector(quitApp)); quit.keyEquivalent = "q"
        item.menu = menu

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { app in
            app.intent.sleeping = true; app.reconcile()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { app in
            app.intent.sleeping = false; app.retryAt = 0; app.failures = 0; app.reconcile()
        }
        for notification in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observe(.default, notification) { $0.reconcile() }
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.updateUI() }
        meterTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.drawMeter() }
        RunLoop.main.add(meterTimer!, forMode: .common)
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(timer!, forMode: .common)
        reconcile()
        if !defaults.bool(forKey: "hasShownHelp") {
            defaults.set(true, forKey: "hasShownHelp"); showHelp()
        }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, handler: @escaping (AppDelegate) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.terminating else { return }; handler(self)
        }
        observers.append((center, token))
    }
    func menuWillOpen(_ menu: NSMenu) { reconcile() }
    private func refreshDevices() {
        available = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if intent.selectedID == nil && !intent.requested {
            intent.selectedID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? available.first?.uniqueID
        }
        if let device = available.first(where: { $0.uniqueID == intent.selectedID }) {
            selectedName = device.localizedName
            UserDefaults.standard.set(device.uniqueID, forKey: "selectedMicrophoneID")
            UserDefaults.standard.set(device.localizedName, forKey: "selectedMicrophoneName")
        }
        deviceMenu.removeAllItems()
        if let id = intent.selectedID, !available.contains(where: { $0.uniqueID == id }) {
            let row = NSMenuItem(title: L("missing"), action: nil, keyEquivalent: "")
            row.isEnabled = false; deviceMenu.addItem(row)
        }
        if available.isEmpty {
            let row = NSMenuItem(title: L("none"), action: nil, keyEquivalent: "")
            row.isEnabled = false; deviceMenu.addItem(row)
        }
        for device in available {
            let row = NSMenuItem(title: device.localizedName, action: #selector(selectDevice(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = device.uniqueID
            row.state = intent.selectedID == device.uniqueID ? .on : .off
            row.isEnabled = !intent.requested && !busy && !requestingPermission
            deviceMenu.addItem(row)
        }
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard !intent.requested && !busy && !requestingPermission else { return }
        intent.selectedID = sender.representedObject as? String
        UserDefaults.standard.set(intent.selectedID, forKey: "selectedMicrophoneID")
        failures = 0; lastError = nil; reconcile()
    }
    private func setRequested(_ value: Bool) {
        intent.requested = value
        UserDefaults.standard.set(value, forKey: "keepAliveRequested")
        retryAt = 0; failures = 0; lastError = nil
        reconcile()
    }
    @objc private func toggleCapture() {
        if intent.requested { setRequested(false); return }
        guard !requestingPermission else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: setRequested(true)
        case .notDetermined:
            requestingPermission = true; updateUI()
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.terminating else { return }
                    self.requestingPermission = false
                    if granted { self.setRequested(true) }
                    else { self.showError(L("denied")); self.updateUI() }
                }
            }
        default: openMicrophoneSettings()
        }
    }
    private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
    @objc private func retryCapture() {
        guard intent.requested else { return }
        guard authorized else { openMicrophoneSettings(); return }
        retryAt = 0; failures = 0; lastError = nil
        if activeID != nil { suspendCapture() } else { reconcile() }
    }
    private func reconcile() {
        guard !terminating else { return }
        refreshDevices()
        switch readiness {
        case .ready(let id):
            if !busy {
                if activeID != nil {
                    if !sink.recent() && now - startedAt > 10 {
                        recordFailure(L("no_audio")); suspendCapture()
                    } else if sink.recent() { failures = 0; lastError = nil }
                } else if now >= retryAt, let device = available.first(where: { $0.uniqueID == id }) {
                    startCapture(device)
                }
            }
        default:
            // Clear an in-flight start too. Completion from its old generation is ignored.
            if activeID != nil { suspendCapture() }
        }
        updateUI()
    }
    private func startCapture(_ device: AVCaptureDevice) {
        let ticket = gate.advance()
        activeID = device.uniqueID; busy = true; startedAt = now
        captureQueue.async {
            guard self.gate.contains(ticket) else { return }
            do {
                self.clearSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self.sink, queue: self.sampleQueue)
                self.session.beginConfiguration()
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "KeepAlive", code: 1, userInfo: [NSLocalizedDescriptionKey: L("input_error")])
                }
                self.session.addInput(input)
                guard self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "KeepAlive", code: 2, userInfo: [NSLocalizedDescriptionKey: L("stream_error")])
                }
                self.session.addOutput(output); self.session.commitConfiguration()
                guard self.gate.contains(ticket) else { self.clearSession(); return }
                self.session.startRunning()
                guard self.session.isRunning else {
                    throw NSError(domain: "KeepAlive", code: 3, userInfo: [NSLocalizedDescriptionKey: L("stream_error")])
                }
                DispatchQueue.main.async {
                    guard self.gate.contains(ticket), !self.terminating else { return }
                    self.busy = false; self.startedAt = self.now; self.reconcile()
                }
            } catch {
                self.clearSession()
                DispatchQueue.main.async {
                    guard self.gate.contains(ticket), !self.terminating else { return }
                    self.activeID = nil; self.busy = false
                    self.recordFailure(error.localizedDescription); self.reconcile()
                }
            }
        }
    }
    /// Only call on captureQueue. Drain old callbacks before allowing another session.
    private func clearSession() {
        session.stopRunning()
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        sampleQueue.sync { self.sink.reset() }
    }
    private func suspendCapture() {
        let ticket = gate.advance()
        activeID = nil; busy = true
        captureQueue.async {
            self.clearSession()
            DispatchQueue.main.async {
                guard self.gate.contains(ticket), !self.terminating else { return }
                self.busy = false; self.reconcile()
            }
        }
    }
    private func recordFailure(_ error: String) {
        failures += 1; lastError = error
        retryAt = now + min(30, pow(2, Double(min(failures, 5))))
    }
    private var message: String {
        switch readiness {
        case .stopped: return busy ? L("stopping") : L("stopped")
        case .sleeping: return L("paused_sleep")
        case .missingDevice: return L("waiting_device")
        case .needsPermission: return L("permission")
        case .ready:
            if busy { return L("starting", selectedName ?? L("unknown_device")) }
            if activeID != nil { return sink.recent() ? L("active") : L("waiting") }
            if let lastError { return L("retry_error", String(max(0, Int(ceil(retryAt - now)))), lastError) }
            return L("waiting")
        }
    }
    private func updateUI() {
        guard item != nil else { return }
        let connected = available.contains(where: { $0.uniqueID == intent.selectedID })
        let name = selectedName ?? (intent.selectedID == nil ? L("unknown_device") : L("saved_device"))
        deviceInfo.title = L("device_connection", name, connected ? L("connected") : L("offline"))
        info.title = L("current_status", message)
        toggle.title = intent.requested ? L("stop") : L("start")
        toggle.isEnabled = !requestingPermission
        retry.isHidden = !intent.requested
        retry.isEnabled = !busy && !intent.sleeping
        restore.state = UserDefaults.standard.bool(forKey: "restoreKeepAliveOnLaunch") ? .on : .off
        let status = SMAppService.mainApp.status
        login.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginApproval.isHidden = status != .requiresApproval
        login.title = status == .requiresApproval ? L("login_pending") : L("launch_at_login")
        item.button?.title = ""
        item.button?.setAccessibilityLabel(deviceInfo.title + ". " + info.title)
        item.button?.toolTip = deviceInfo.title + "\n" + info.title
        drawMeter()
    }
    private func drawMeter() {
        if intent.requested && !intent.sleeping && activeID != nil && !busy && sink.recent() {
            levels.removeFirst(); levels.append(sink.meter()); item.button?.image = meterImage(levels)
        } else {
            levels = Array(repeating: 0, count: 5)
            item.button?.image = NSImage(systemSymbolName: intent.requested ? "pause.circle" : "mic.slash", accessibilityDescription: message)
        }
    }
    @objc private func toggleRestore() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "restoreKeepAliveOnLaunch"), forKey: "restoreKeepAliveOnLaunch")
        // Only affects the next launch. Never activates the mic just by changing a preference.
        updateUI()
    }
    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval: try SMAppService.mainApp.unregister()
            default:
                let path = Bundle.main.bundleURL.standardizedFileURL.path
                let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
                guard path.hasPrefix("/Applications/") || path.hasPrefix(userApps) else {
                    showError(L("install_for_login")); return
                }
                try SMAppService.mainApp.register()
            }
        } catch { showError(L("login_error", error.localizedDescription)) }
        updateUI()
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = L("title"); alert.informativeText = text
        alert.addButton(withTitle: L("ok")); alert.runModal()
    }
    @objc private func showHelp() { showError(L("instructions")) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true; gate.advance()
        timer?.invalidate(); meterTimer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
        // Preserve user intent for the optional next-launch restore, but release capture now.
        captureQueue.sync { self.clearSession() }
    }
}
if CommandLine.arguments.contains("--localization-report") {
    print("Language: \(L10n.language)")
    print(L("start")); print(L("starting", "Test Mic")); print(L("help"))
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    L10n.validateResources()
    runRecoveryTests()
    assert(normalizedLevel(-160) == 0)
    assert(normalizedLevel(-60) == 0)
    assert(normalizedLevel(-30) == 0.5)
    assert(normalizedLevel(0) == 1)
    assert(normalizedLevel(10) == 1)
    assert(normalizedLevel(.nan) == 0)
    let sink = SampleSink()
    assert(!sink.recent() && sink.meter() == 0)
    sink.reset(); assert(!sink.recent())
    try! FileManager.default.createDirectory(atPath: ".build", withIntermediateDirectories: true)
    let image = meterImage([0.1, 0.4, 0.9, 0.7, 0.3])
    assert(image.size.width == 36 && image.isTemplate)
    if let data = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: ".build/meter-preview.png"))
    }
    print("PASS: meter mapping, silent/stale state, icon rendering")
    exit(0)
}
if CommandLine.arguments.contains("--list-devices") {
    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    for device in devices {
        print("Audio input detected: \(device.localizedName)")
    }
    exit(devices.isEmpty ? 2 : 0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
