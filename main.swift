import AppKit
import AVFoundation
import ServiceManagement

// Buffers are discarded; retain only a timestamp and scalar meter value.
func normalizedLevel(_ decibels: Float) -> Double {
    guard decibels.isFinite else { return 0 }
    return min(1, max(0, (Double(decibels) + 60) / 60))
}
enum MicIndicator: String, CaseIterable {
    case disconnected, standby, waiting, quiet, signal
    static func resolve(connected: Bool, requested: Bool, healthy: Bool, level: Double) -> MicIndicator {
        guard connected else { return .disconnected }
        guard requested else { return .standby }
        guard healthy else { return .waiting }
        return level > 0.08 ? .signal : .quiet
    }
    var textKey: String { "indicator_" + rawValue }
}
func meterImage(_ levels: [Double], state: MicIndicator = .signal) -> NSImage {
    let width: CGFloat = state == .standby ? 16 : 26
    let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let capsule = NSBezierPath(roundedRect: NSRect(x: 5, y: 7, width: 6, height: 10), xRadius: 3, yRadius: 3)
        capsule.lineWidth = 1.2
        capsule.stroke()
        if state == .quiet || state == .signal {
            // Fill the microphone itself: no separate bars or reserved empty space.
            let level = min(1, max(0, levels.last ?? 0))
            NSGraphicsContext.saveGraphicsState()
            capsule.addClip()
            NSRect(x: 5, y: 7, width: 6, height: 10 * level).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let cradle = NSBezierPath()
        cradle.lineWidth = 1.2; cradle.lineCapStyle = .round
        cradle.move(to: NSPoint(x: 2.5, y: 10))
        cradle.line(to: NSPoint(x: 2.5, y: 8))
        cradle.curve(to: NSPoint(x: 13.5, y: 8), controlPoint1: NSPoint(x: 2.5, y: 1.5), controlPoint2: NSPoint(x: 13.5, y: 1.5))
        cradle.line(to: NSPoint(x: 13.5, y: 10))
        cradle.move(to: NSPoint(x: 8, y: 3))
        cradle.line(to: NSPoint(x: 8, y: 1))
        cradle.move(to: NSPoint(x: 5.5, y: 1))
        cradle.line(to: NSPoint(x: 10.5, y: 1))
        cradle.stroke()
        let badge: String?
        switch state {
        case .disconnected: badge = "xmark.circle"
        case .standby: badge = nil
        case .waiting: badge = "hourglass"
        case .quiet, .signal: badge = "checkmark.shield.fill"
        }
        if let badge {
            NSImage(systemSymbolName: badge, accessibilityDescription: nil)?.draw(in: NSRect(x: 16, y: 1, width: 10, height: 11))
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

/// A control inside the menu handles selection without ending menu tracking.
final class DeviceChoiceButton: NSButton {
    var choose: (() -> Void)?
    private var selected = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    init(title: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        self.title = title
        isBordered = false
        alignment = .left
        font = .menuFont(ofSize: 0)
        imagePosition = .imageLeading
        imageHugsTitle = true
        setButtonType(.momentaryChange)
        target = self; action = #selector(selectChoice)
        autoresizingMask = [.width]
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func selectChoice() { choose?() }
    func update(selected: Bool, enabled: Bool) {
        self.selected = selected
        isEnabled = enabled
        setAccessibilityValue(selected ? 1 : 0)
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isEnabled && (hovered || isHighlighted)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = !isEnabled ? .disabledControlTextColor : (highlighted ? .alternateSelectedControlTextColor : .labelColor)
        if selected {
            // A small, aligned checkmark; unselected rows leave this column empty.
            color.setStroke()
            let check = NSBezierPath()
            check.lineWidth = 1.6; check.lineCapStyle = .round; check.lineJoinStyle = .round
            let y = bounds.midY
            check.move(to: NSPoint(x: 12, y: y))
            check.line(to: NSPoint(x: 15, y: y + (isFlipped ? 3 : -3)))
            check.line(to: NSPoint(x: 20, y: y + (isFlipped ? -4 : 4)))
            check.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.menuFont(ofSize: 0), .foregroundColor: color]
        let text = title as NSString
        let height = text.size(withAttributes: attributes).height
        text.draw(at: NSPoint(x: 30, y: (bounds.height - height) / 2), withAttributes: attributes)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var info: NSMenuItem!
    private var signalInfo: NSMenuItem!
    private var lastIndicator: MicIndicator?
    private var deviceInfo: NSMenuItem!
    private var systemInfo: NSMenuItem!
    private var systemInputID: String?
    private var toggle: NSMenuItem!
    private var retry: NSMenuItem!
    private var login: NSMenuItem!
    private var restore: NSMenuItem!
    private var loginApproval: NSMenuItem!
    private var deviceMenu: NSMenu!
    private var deviceMenuOpen = false
    private let usage = DeviceUsage(defaults: .standard)
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
        systemInfo = NSMenuItem(title: "", action: nil, keyEquivalent: ""); systemInfo.isEnabled = false
        signalInfo = NSMenuItem(title: "", action: nil, keyEquivalent: ""); signalInfo.isEnabled = false
        menu.addItem(systemInfo); menu.addItem(deviceInfo); menu.addItem(info); menu.addItem(signalInfo); menu.addItem(.separator())
        func action(_ key: String, _ selector: Selector) -> NSMenuItem {
            let row = NSMenuItem(title: L(key), action: selector, keyEquivalent: "")
            row.target = self; menu.addItem(row); return row
        }
        toggle = action("start", #selector(toggleCapture))
        retry = action("retry_now", #selector(retryCapture))
        let devicesItem = NSMenuItem(title: L("choose"), action: nil, keyEquivalent: "")
        deviceMenu = NSMenu(); deviceMenu.autoenablesItems = false; deviceMenu.delegate = self
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
    func menuWillOpen(_ menu: NSMenu) {
        if menu === deviceMenu { deviceMenuOpen = false }
        reconcile()
        if menu === deviceMenu { deviceMenuOpen = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === deviceMenu { deviceMenuOpen = false }
    }
    private func refreshDevices() {
        available = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let currentSystemID = SystemAudio.inputUID
        intent.followSystemInput(currentSystemID, previous: systemInputID, availableIDs: Set(available.map(\.uniqueID)))
        systemInputID = currentSystemID
        if let device = available.first(where: { $0.uniqueID == intent.selectedID }) {
            selectedName = device.localizedName
            UserDefaults.standard.set(device.uniqueID, forKey: "selectedMicrophoneID")
            UserDefaults.standard.set(device.localizedName, forKey: "selectedMicrophoneName")
        }
        // Never rebuild or reorder rows under the pointer while the submenu is open.
        if deviceMenuOpen {
            for row in deviceMenu.items {
                guard let id = row.representedObject as? String else { continue }
                row.state = systemInputID == id ? .on : .off
                row.isEnabled = !intent.sleeping && !requestingPermission && available.contains { $0.uniqueID == id }
                (row.view as? DeviceChoiceButton)?.update(selected: row.state == .on, enabled: row.isEnabled)
            }
            return
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
        let sorted = available.sorted { usage.precedes($0.uniqueID, name: $0.localizedName, $1.uniqueID, name: $1.localizedName) }
        let width = max(180, sorted.map { ($0.localizedName as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width + 46 }.max() ?? 180)
        for device in sorted {
            let row = NSMenuItem(title: device.localizedName, action: #selector(selectDevice(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = device.uniqueID
            row.state = systemInputID == device.uniqueID ? .on : .off
            row.isEnabled = !intent.sleeping && !requestingPermission
            let button = DeviceChoiceButton(title: device.localizedName, width: width)
            button.update(selected: row.state == .on, enabled: row.isEnabled)
            button.choose = { [weak self, weak row] in
                guard let row else { return }; self?.selectDevice(row)
            }
            row.view = button
            deviceMenu.addItem(row)
        }
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard !intent.sleeping, !requestingPermission, let id = sender.representedObject as? String else { return }
        do {
            let changed = SystemAudio.inputUID != id || intent.selectedID != id
            try SystemAudio.selectInput(uid: id)
            if changed { usage.record(id) }
            intent.selectedID = id
            systemInputID = id
            UserDefaults.standard.set(id, forKey: "selectedMicrophoneID")
            retryAt = 0; failures = 0; lastError = nil
        } catch { showError(L("switch_error", error.localizedDescription)) }
        reconcile()
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
            if let activeID, activeID != id {
                retryAt = 0; failures = 0; lastError = nil
                suspendCapture()
            }
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
        let systemName = available.first(where: { $0.uniqueID == systemInputID })?.localizedName ?? L("unknown_device")
        systemInfo.title = L("system_input", systemName)
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
        item.button?.setAccessibilityLabel(systemInfo.title + ". " + deviceInfo.title + ". " + info.title)
        item.button?.toolTip = systemInfo.title + "\n" + deviceInfo.title + "\n" + info.title
        drawMeter()
    }
    private func drawMeter() {
        let healthy = intent.requested && !intent.sleeping && activeID != nil && !busy && sink.recent()
        let connected = available.contains { $0.uniqueID == intent.selectedID }
        let level = healthy ? sink.meter() : 0
        let state = MicIndicator.resolve(connected: connected, requested: intent.requested, healthy: healthy, level: level)
        if healthy {
            levels.removeFirst(); levels.append(level)
        } else { levels = Array(repeating: 0, count: 5) }
        item.button?.image = meterImage(levels, state: state)
        signalInfo.title = L(state.textKey)
        let description = systemInfo.title + "\n" + deviceInfo.title + "\n" + info.title + "\n" + signalInfo.title
        item.button?.toolTip = description
        if state != lastIndicator {
            item.button?.setAccessibilityLabel(description)
            lastIndicator = state
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
    runDeviceUsageTests()
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
    assert(image.size.width == 26 && image.isTemplate)
    if let data = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: ".build/meter-preview.png"))
    }
    assert(MicIndicator.resolve(connected: false, requested: true, healthy: false, level: 0) == .disconnected)
    assert(MicIndicator.resolve(connected: true, requested: false, healthy: false, level: 1) == .standby)
    assert(MicIndicator.resolve(connected: true, requested: true, healthy: false, level: 1) == .waiting)
    assert(MicIndicator.resolve(connected: true, requested: true, healthy: true, level: 0) == .quiet)
    assert(MicIndicator.resolve(connected: true, requested: true, healthy: true, level: 0.5) == .signal)
    for state in MicIndicator.allCases {
        let preview = meterImage(state == .quiet ? [0, 0, 0, 0] : [0.1, 0.4, 0.9, 0.5], state: state)
        assert(preview.isTemplate && preview.size.width == (state == .standby ? 16 : 26))
        if let data = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try! png.write(to: URL(fileURLWithPath: ".build/indicator-\(state.rawValue).png"))
        }
    }
    print("PASS: connection, unmonitored input, waiting, healthy quiet and signal indicators")
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
