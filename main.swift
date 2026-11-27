import AppKit
import AVFoundation
import ServiceManagement
import CoreAudio

// Audio is never saved. Optional enhancement forwards transient buffers to BlackHole.
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
func meterImage(_ levels: [Double], state: MicIndicator = .signal, enhanced: Bool = false) -> NSImage {
    let width: CGFloat = state == .standby ? 16 : 32
    let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        NSGraphicsContext.saveGraphicsState()
        let micOffset = NSAffineTransform(); micOffset.translateX(by: 0, yBy: 2); micOffset.concat()
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
        NSGraphicsContext.restoreGraphicsState()
        let badge: String?
        switch state {
        case .disconnected: badge = "xmark.circle"
        case .standby: badge = nil
        case .waiting: badge = "hourglass"
        case .quiet, .signal: badge = "checkmark.shield.fill"
        }
        if let badge {
            NSImage(systemSymbolName: badge, accessibilityDescription: nil)?.draw(in: NSRect(x: 18, y: 0.5, width: 12, height: 11))
        }
        if enhanced && (state == .quiet || state == .signal) {
            // A bold plus stays legible at menu-bar size.
            let plus = NSBezierPath()
            plus.lineWidth = 2; plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: 20.5, y: 17.5))
            plus.line(to: NSPoint(x: 27.5, y: 17.5))
            plus.move(to: NSPoint(x: 24, y: 14))
            plus.line(to: NSPoint(x: 24, y: 21))
            plus.stroke()
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
    // Accessed only from sampleQueue.
    var enhancement: EnhancementRouter?
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        enhancement?.consume(sampleBuffer)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let panel = ControlPanel()
    private let updates = UpdateChecker()
    private let installer = UpdateInstaller()
    private let popover = NSPopover()
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var systemInputID: String?
    private var enhancementEnabled: Bool { intent.enhancement }
    private var boostStoppedNotice = false
    private var enhancementGain: Float = 12
    private var voiceOptions = VoiceProcessingOptions()
    private var lastIndicator: MicIndicator?
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
    private var captureRequested: Bool { intent.requested }
    private var readiness: KeepAliveIntent.Readiness {
        intent.readiness(availableIDs: Set(available.map(\.uniqueID)), authorized: authorized)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        intent = KeepAliveIntent(selectedID: defaults.string(forKey: "selectedMicrophoneID"),
                                 restoreOnLaunch: defaults.bool(forKey: "restoreKeepAliveOnLaunch"),
                                 wasRequested: defaults.bool(forKey: "keepAliveRequested"))
        selectedName = defaults.string(forKey: "selectedMicrophoneName")
        var restoredUpdateToken: String?
        if let token = UpdateResume.launchToken, let resume = try? UpdateResume.consume(token: token) {
            restoredUpdateToken = token
            intent = KeepAliveIntent(selectedID: resume.selectedID, restoreOnLaunch: resume.requested, wasRequested: resume.requested)
            intent.setEnhancement(resume.enhancement)
            enhancementGain = resume.gain
            voiceOptions = VoiceProcessingOptions(noiseReduction: resume.noiseReduction, voiceClarity: resume.voiceClarity)
            selectedName = resume.selectedName
        }
        defaults.set(intent.requested, forKey: "keepAliveRequested")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover.contentViewController = panel
        popover.behavior = .applicationDefined
        popover.animates = false
        _ = panel.view
        panel.resize = { [weak self] size in
            guard let self, self.popover.contentSize != size else { return }
            self.popover.contentSize = size
        }
        panel.toggleCapture = { [weak self] in self?.toggleCapture() }
        panel.chooseDevice = { [weak self] id in self?.selectDevice(id) }
        panel.toggleEnhancement = { [weak self] in self?.toggleEnhancement() }
        panel.chooseGain = { [weak self] gain in self?.changeEnhancementGain(gain) }
        panel.toggleNoiseReduction = { [weak self] in
            guard let self else { return }
            self.voiceOptions.noiseReduction.toggle(); self.updateVoiceProcessing(); self.updateUI()
        }
        panel.toggleVoiceClarity = { [weak self] in
            guard let self else { return }
            self.voiceOptions.voiceClarity.toggle(); self.updateVoiceProcessing(); self.updateUI()
        }
        panel.retry = { [weak self] in self?.retryCapture() }
        panel.toggleLogin = { [weak self] in self?.toggleLogin() }
        panel.toggleRestore = { [weak self] in self?.toggleRestore() }
        panel.help = { [weak self] in self?.showHelp() }
        panel.enhancementHelp = { [weak self] in self?.showEnhancementHelp() }
        panel.install = { [weak self] in self?.openDriverInstallation() }
        panel.recheck = { [weak self] in
            guard let self else { return }
            self.reconcile()
            self.showError(L((try? EnhancementRouter.destination()) != nil ? "panel_driver_ready" : "panel_install_hint"))
        }
        panel.loginSettings = { [weak self] in self?.openLoginSettings() }
        panel.quit = { [weak self] in self?.quitApp() }
        updates.onChange = { [weak self] state in self?.panel.updateReleaseState(state) }
        installer.onChange = { [weak self] state in self?.panel.updateInstallationState(state) }
        installer.onPrepared = { [weak self] prepared in
            guard let self else { return }
            do {
                let resume = UpdateResume(requested: self.intent.requested, enhancement: self.enhancementEnabled,
                    gain: self.enhancementGain, noiseReduction: self.voiceOptions.noiseReduction, voiceClarity: self.voiceOptions.voiceClarity,
                    selectedID: self.intent.selectedID, selectedName: self.selectedName)
                try self.installer.launch(prepared, resume: resume) { NSApp.terminate(nil) }
            } catch { self.installer.fail(error) }
        }
        panel.checkOrDownloadUpdate = { [weak self] in
            guard let self else { return }
            if let release = self.updates.state.available {
                self.installer.begin(release)
            } else { self.updates.check() }
        }
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanelIfOutside()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            } else { self.closePanelIfOutside() }
            return event
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { app in
            app.intent.sleeping = true; app.reconcile()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { app in
            app.intent.sleeping = false; app.retryAt = 0; app.failures = 0; app.reconcile()
            app.updates.checkIfDue()
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
        updates.start()
        if let token = restoredUpdateToken {
            try? UpdateResume.acknowledge(token: token)
            togglePanel()
        }
        let updateError = UpdateFiles.root.appendingPathComponent("last-update-error.txt")
        if let detail = try? String(contentsOf: updateError, encoding: .utf8) {
            try? FileManager.default.removeItem(at: updateError)
            showError(L("update_install_failed", detail))
        }
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
    private func closePanelIfOutside() {
        guard popover.isShown else { return }
        let location = NSEvent.mouseLocation
        if panel.view.window?.frame.contains(location) == true { return }
        if let button = item.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(location) { return }
        popover.performClose(nil)
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        panel.beginPresentation()
        reconcile()
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.view.window?.makeFirstResponder(nil)

    }
    private func openDriverInstallation() {
        panel.showNotice(L("panel_install_hint"))
        NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!)
    }
    private func refreshDevices() {
        available = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let currentSystemID = SystemAudio.inputUID
        if !enhancementEnabled {
            intent.followSystemInput(currentSystemID, previous: systemInputID, availableIDs: Set(available.map(\.uniqueID)))
        }
        systemInputID = currentSystemID
        if let device = available.first(where: { $0.uniqueID == intent.selectedID }) {
            selectedName = device.localizedName
            UserDefaults.standard.set(device.uniqueID, forKey: "selectedMicrophoneID")
            UserDefaults.standard.set(device.localizedName, forKey: "selectedMicrophoneName")
        }
    }
    private func selectDevice(_ id: String) {
        guard !intent.sleeping, !requestingPermission else { return }
        do {
            let changed = SystemAudio.inputUID != id || intent.selectedID != id
            guard !enhancementEnabled || id != EnhancementRouter.destinationUID else { return }
            try SystemAudio.selectInput(uid: id)
            if changed { usage.record(id) }
            intent.selectedID = id
            systemInputID = id
            UserDefaults.standard.set(id, forKey: "selectedMicrophoneID")
            retryAt = 0; failures = 0; lastError = nil
        } catch { showError(L("switch_error", error.localizedDescription)) }
        reconcile()
    }
    @objc private func showEnhancementHelp() { showError(L("enhance_instructions")) }
    @objc private func toggleEnhancement() {
        guard !requestingPermission else { return }
        if !enhancementEnabled {
            if !authorized {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    requestingPermission = true; updateUI()
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                        DispatchQueue.main.async {
                            guard let self, !self.terminating else { return }
                            self.requestingPermission = false
                            if granted { self.toggleEnhancement() }
                            else { self.showError(L("denied")); self.updateUI() }
                        }
                    }
                } else { openMicrophoneSettings() }
                return
            }
            guard let id = intent.selectedID, id != EnhancementRouter.destinationUID else { showError(L("enhance_source")); updateUI(); return }
            do { _ = try EnhancementRouter.destination() }
            catch { showError(error.localizedDescription); updateUI(); return }
        }
        intent.setEnhancement(!enhancementEnabled)
        boostStoppedNotice = !enhancementEnabled
        UserDefaults.standard.set(intent.requested, forKey: "keepAliveRequested")
        retryAt = 0; failures = 0; lastError = nil
        if activeID != nil { suspendCapture() } else { reconcile() }
    }
    private func changeEnhancementGain(_ gain: Float) {
        guard [Float(6), 12, 18].contains(gain), gain != enhancementGain else { return }
        enhancementGain = gain
        updateVoiceProcessing(); updateUI()
    }
    private func updateVoiceProcessing() {
        let gain = enhancementGain, options = voiceOptions
        sampleQueue.async { self.sink.enhancement?.updateProcessing(gainDB: gain, options: options) }
    }
    private func setRequested(_ value: Bool) {
        if !value && enhancementEnabled { boostStoppedNotice = true }
        intent.setRequested(value)
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
        guard captureRequested else { return }
        guard authorized else { openMicrophoneSettings(); return }
        retryAt = 0; failures = 0; lastError = nil
        if activeID != nil { suspendCapture() } else { reconcile() }
    }
    private func reconcile() {
        guard !terminating else { return }
        refreshDevices()
        var outputError: String?
        if enhancementEnabled, activeID != nil, !busy {
            let outputState = sampleQueue.sync { (sink.enhancement?.error, sink.enhancement?.retryAt ?? 0) }
            outputError = outputState.0
            if let error = outputError {
                lastError = error; retryAt = outputState.1
            }
        }
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
                    } else if sink.recent() && outputError == nil { failures = 0; lastError = nil }
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
        let enhance = enhancementEnabled, gain = enhancementGain, options = voiceOptions
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
                guard self.gate.contains(ticket) else { self.clearSession(); return }
                if enhance {
                    guard device.uniqueID != EnhancementRouter.destinationUID else { throw NSError(domain: "MicEnhancement", code: 2, userInfo: [NSLocalizedDescriptionKey: L("enhance_source")]) }
                    let router = try EnhancementRouter(gainDB: gain, options: options)
                    self.sampleQueue.sync { self.sink.enhancement = router }
                }
                DispatchQueue.main.async {
                    guard self.gate.contains(ticket), !self.terminating else { return }
                    self.busy = false; self.startedAt = self.now
                    self.updateVoiceProcessing() // Apply any changes made while capture was starting.
                    self.reconcile()
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
        sampleQueue.sync {
            self.sink.enhancement?.stop(); self.sink.enhancement = nil
            self.sink.reset()
        }
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
            if let lastError {
                let seconds = Int(ceil(retryAt - now))
                return seconds > 0 ? L("retry_error", String(seconds), lastError) : L("retrying_error", lastError)
            }
            if activeID != nil { return sink.recent() ? L(enhancementEnabled ? "boost_active_status" : "active") : L("waiting") }
            return L("waiting")
        }
    }
    private func updateUI() {
        guard item != nil else { return }
        func isVirtual(_ device: AVCaptureDevice) -> Bool {
            let type = UInt32(bitPattern: device.transportType)
            return type == kAudioDeviceTransportTypeVirtual || type == kAudioDeviceTransportTypeAggregate
        }
        let sorted = available.sorted {
            if isVirtual($0) != isVirtual($1) { return !isVirtual($0) }
            return usage.precedes($0.uniqueID, name: $0.localizedName, $1.uniqueID, name: $1.localizedName)
        }
        var devices = sorted.map { PanelDevice(id: $0.uniqueID, name: $0.localizedName, enabled: !enhancementEnabled || $0.uniqueID != EnhancementRouter.destinationUID, isVirtual: isVirtual($0)) }
        if let id = intent.selectedID, !available.contains(where: { $0.uniqueID == id }) {
            devices.insert(PanelDevice(id: id, name: (selectedName ?? L("saved_device")) + " · " + L("offline"), enabled: false), at: 0)
        }
        let loginStatus = SMAppService.mainApp.status
        let healthy = captureRequested && activeID != nil && !busy && sink.recent() && lastError == nil
        panel.update(PanelState(devices: devices, selectedID: intent.selectedID,
            systemName: available.first(where: { $0.uniqueID == systemInputID })?.localizedName ?? L("unknown_device"),
            status: message, requested: intent.requested, canToggle: !requestingPermission,
            enhancement: enhancementEnabled, gain: enhancementGain,
            driverInstalled: (try? EnhancementRouter.destination()) != nil, sending: healthy && enhancementEnabled,
            canRetry: !busy && !intent.sleeping,
            loginState: loginStatus == .enabled ? .on : (loginStatus == .requiresApproval ? .mixed : .off),
            loginPending: loginStatus == .requiresApproval,
            restore: UserDefaults.standard.bool(forKey: "restoreKeepAliveOnLaunch"), boostStoppedNotice: boostStoppedNotice,
            voiceOptions: voiceOptions))
        item.button?.title = ""
        drawMeter()
    }
    private func drawMeter() {
        let healthy = captureRequested && !intent.sleeping && activeID != nil && !busy && sink.recent() && lastError == nil
        let connected = available.contains { $0.uniqueID == intent.selectedID }
        let level = healthy ? sink.meter() : 0
        let state = MicIndicator.resolve(connected: connected, requested: captureRequested, healthy: healthy, level: level)
        if healthy {
            levels.removeFirst(); levels.append(level)
        } else { levels = Array(repeating: 0, count: 5) }
        item.button?.image = meterImage(levels, state: state, enhanced: enhancementEnabled && healthy)
        let description = (selectedName ?? L("unknown_device")) + "\n" + message + "\n" + L(state.textKey)
        item.button?.toolTip = description
        if state != lastIndicator || enhancementEnabled {
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
        if !popover.isShown { togglePanel() }
        panel.showNotice(text)
    }
    @objc private func showHelp() { showError(L("instructions")) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true; gate.advance()
        timer?.invalidate(); meterTimer?.invalidate()
        updates.stop()
        installer.stop()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
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
    runEnhancementTests()
    ControlPanel.runTests()
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
    assert(image.size.width == 32 && image.isTemplate)
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
        assert(preview.isTemplate && preview.size.width == (state == .standby ? 16 : 32))
        if let data = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try! png.write(to: URL(fileURLWithPath: ".build/indicator-\(state.rawValue).png"))
        }
    }
    let enhancedIcon = meterImage([0.6], state: .signal, enhanced: true)
    assert(enhancedIcon.isTemplate && enhancedIcon.size == NSSize(width: 32, height: 22))
    if let data = enhancedIcon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: ".build/indicator-enhanced.png"))
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
