import AppKit
import AVFoundation

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var info: NSMenuItem!
    private var toggle: NSMenuItem!
    private var deviceMenu: NSMenu!
    private let session = AVCaptureSession()
    private let sink = SampleSink()
    private let captureQueue = DispatchQueue(label: "local.mic.keepalive.capture")
    private let sampleQueue = DispatchQueue(label: "local.mic.keepalive.discard")
    private var selectedID: String?
    private var activeID: String?
    private var enabled = false
    private var busy = false
    private var generation = 0
    private var timer: Timer?
    private var meterTimer: Timer?
    private var levels = Array(repeating: 0.0, count: 5)
    private var message = L("stopped")

    private func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        info = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        menu.addItem(info)
        toggle = NSMenuItem(title: L("start"), action: #selector(toggleCapture), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        let devicesItem = NSMenuItem(title: L("choose"), action: nil, keyEquivalent: "")
        deviceMenu = NSMenu(); devicesItem.submenu = deviceMenu; menu.addItem(devicesItem)
        menu.addItem(.separator())
        let help = NSMenuItem(title: L("help"), action: #selector(showHelp), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        let quit = NSMenuItem(title: L("quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        selectedID = UserDefaults.standard.string(forKey: "selectedMicrophoneID")
        refreshDevices(); updateUI()
        meterTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.drawMeter() }
        RunLoop.main.add(meterTimer!, forMode: .common)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        if !UserDefaults.standard.bool(forKey: "hasShownHelp") {
            UserDefaults.standard.set(true, forKey: "hasShownHelp")
            showHelp()
        }
    }
    private func refreshDevices() {
        let available = devices()
        if selectedID == nil {
            selectedID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? available.first?.uniqueID
        }
        deviceMenu.removeAllItems()
        if let selectedID, !available.contains(where: { $0.uniqueID == selectedID }) {
            deviceMenu.addItem(NSMenuItem(title: L("missing"), action: nil, keyEquivalent: ""))
        }
        if available.isEmpty { deviceMenu.addItem(NSMenuItem(title: L("none"), action: nil, keyEquivalent: "")) }
        for device in available {
            let row = NSMenuItem(title: device.localizedName, action: #selector(selectDevice(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = device.uniqueID
            row.state = selectedID == device.uniqueID ? .on : .off
            row.isEnabled = !enabled && !busy
            deviceMenu.addItem(row)
        }
        deviceMenu.autoenablesItems = false
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard !enabled && !busy else { return }
        selectedID = sender.representedObject as? String
        UserDefaults.standard.set(selectedID, forKey: "selectedMicrophoneID")
        refreshDevices()
    }
    @objc private func toggleCapture() {
        guard !busy else { return }
        if enabled { stop(L("stopped")); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: start()
        case .notDetermined:
            busy = true; updateUI()
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.busy = false
                    if granted { self.start() }
                    else { self.message = L("denied"); self.updateUI() }
                }
            }
        default:
            message = L("permission"); updateUI()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    private func start() {
        guard let device = devices().first(where: { $0.uniqueID == selectedID }) else {
            message = L("connect"); refreshDevices(); updateUI(); return
        }
        UserDefaults.standard.set(device.uniqueID, forKey: "selectedMicrophoneID")
        generation += 1; let ticket = generation
        busy = true; enabled = true; activeID = device.uniqueID
        sink.reset(); levels = Array(repeating: 0, count: 5); message = L("starting", device.localizedName); updateUI()
        captureQueue.async {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self.sink, queue: self.sampleQueue)
                self.session.beginConfiguration()
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration(); throw NSError(domain: "KeepAlive", code: 1, userInfo: [NSLocalizedDescriptionKey: L("input_error")])
                }
                self.session.addInput(input)
                guard self.session.canAddOutput(output) else {
                    self.session.removeInput(input); self.session.commitConfiguration()
                    throw NSError(domain: "KeepAlive", code: 2, userInfo: [NSLocalizedDescriptionKey: L("stream_error")])
                }
                self.session.addOutput(output); self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    guard self.generation == ticket else { return }
                    self.busy = false; self.message = L("waiting"); self.updateUI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        if self.generation == ticket && self.enabled && !self.sink.recent() {
                            self.stop(L("no_audio"))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == ticket else { return }
                    self.stop(L("failed", error.localizedDescription))
                }
            }
        }
    }
    private func stop(_ reason: String) {
        generation += 1; enabled = false; busy = true; activeID = nil
        message = reason; updateUI()
        captureQueue.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration(); self.sink.reset()
            DispatchQueue.main.async { self.busy = false; self.updateUI(); self.refreshDevices() }
        }
    }
    private func tick() {
        refreshDevices()
        if enabled && !busy {
            if !devices().contains(where: { $0.uniqueID == activeID }) {
                stop(L("disconnected")); return
            }
            message = sink.recent() ? L("active") : L("interrupted")
        }
        updateUI()
    }
    private func updateUI() {
        info.title = message
        toggle.title = enabled ? L("stop") : L("start")
        toggle.isEnabled = !busy
        item.menu?.autoenablesItems = false
        item.button?.title = ""
        item.button?.setAccessibilityLabel(message)
        drawMeter()
        item.button?.toolTip = L("tooltip", message)
    }
    private func drawMeter() {
        if enabled && !busy && sink.recent() {
            levels.removeFirst(); levels.append(sink.meter())
            item.button?.image = meterImage(levels)
        } else {
            levels = Array(repeating: 0, count: 5)
            item.button?.image = NSImage(systemSymbolName: enabled ? "mic.badge.ellipsis" : "mic.slash", accessibilityDescription: message)
        }
    }
    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("title")
        alert.informativeText = L("instructions")
        alert.addButton(withTitle: L("ok")); alert.runModal()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); meterTimer?.invalidate()
        captureQueue.sync { self.session.stopRunning() }
    }
}
if CommandLine.arguments.contains("--localization-report") {
    print("Language: \(L10n.language)")
    print(L("start")); print(L("starting", "Test Mic")); print(L("help"))
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    L10n.validateResources()
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
