import AppKit

struct PanelDevice: Equatable {
    let id: String
    let name: String
    let enabled: Bool
    var isVirtual: Bool = false
}
struct PanelState {
    var devices: [PanelDevice]
    var selectedID: String?
    var systemName: String
    var status: String
    var requested: Bool
    var canToggle: Bool
    var enhancement: Bool
    var gain: Float
    var driverInstalled: Bool
    var sending: Bool
    var canRetry: Bool
    var loginState: NSControl.StateValue
    var loginPending: Bool
    var restore: Bool
    var boostStoppedNotice: Bool = false
}
private final class PanelDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Keep the symbol and label together instead of stretching them across the tile.
private final class TileCell: NSButtonCell {
    private func contentRects(in bounds: NSRect) -> (NSRect, NSRect) {
        let iconSize: CGFloat = 14
        let gap: CGFloat = 7
        let available = max(1, bounds.width - 16 - iconSize - gap)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12)]
        let text = NSAttributedString(string: title, attributes: attributes)
        let naturalWidth = ceil(text.size().width)
        let textWidth = min(available, naturalWidth)
        let textHeight = min(bounds.height - 8, ceil(text.boundingRect(
            with: NSSize(width: textWidth, height: bounds.height - 8),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
        let start = bounds.midX - (iconSize + gap + textWidth) / 2
        return (NSRect(x: start, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize),
                NSRect(x: start + iconSize + gap, y: bounds.midY - textHeight / 2, width: textWidth, height: textHeight))
    }
    override func imageRect(forBounds rect: NSRect) -> NSRect { contentRects(in: rect).0 }
    override func titleRect(forBounds rect: NSRect) -> NSRect { contentRects(in: rect).1 }
}

private final class DeviceTile: NSButton {
    let deviceID: String
    let deviceName: String
    let virtual: Bool
    var updateSurface: ((Bool) -> Void)?
    init(_ device: PanelDevice) {
        deviceID = device.id; deviceName = device.name; virtual = device.isVirtual
        super.init(frame: .zero)
        cell = TileCell(textCell: device.name)
        title = device.name; alternateTitle = device.name; toolTip = device.name
        setButtonType(.momentaryPushIn); isBordered = false
        (cell as? NSButtonCell)?.showsStateBy = []
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .center
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        (cell as? NSButtonCell)?.wraps = true
        (cell as? NSButtonCell)?.lineBreakMode = .byWordWrapping
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel(device.name)
        heightAnchor.constraint(equalToConstant: 48).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(selected: Bool, enabled: Bool, uncheckedSymbol: String? = nil) {
        state = selected ? .on : .off; isEnabled = enabled
        image = NSImage(systemSymbolName: selected ? "checkmark.circle.fill" : (uncheckedSymbol ?? (virtual ? "waveform" : "mic")), accessibilityDescription: nil)
        contentTintColor = selected ? .controlAccentColor : .labelColor
        updateSurface?(selected)
        setAccessibilityValue(selected ? 1 : 0)
    }
}

/// Ordinary AppKit controls in a transient popover: actions never dismiss it.
final class ControlPanel: NSViewController {
    var toggleCapture: (() -> Void)?
    var chooseDevice: ((String) -> Void)?
    var toggleEnhancement: (() -> Void)?
    var chooseGain: ((Float) -> Void)?
    var retry: (() -> Void)?
    var toggleLogin: (() -> Void)?
    var toggleRestore: (() -> Void)?
    var help: (() -> Void)?
    var enhancementHelp: (() -> Void)?
    var install: (() -> Void)?
    var recheck: (() -> Void)?
    var loginSettings: (() -> Void)?
    var quit: (() -> Void)?

    private let source = NSScrollView()
    private let deviceStack = NSStackView()
    private let virtualSource = NSScrollView()
    private let virtualStack = NSStackView()
    private var virtualHeight: NSLayoutConstraint!
    private var virtualHeader: NSStackView!
    private var virtualTitle: NSTextField!
    private var deviceHeight: NSLayoutConstraint!
    private var tiles: [DeviceTile] = []
    private var virtualButton: NSButton!
    private var showVirtual = false
    private var latestState: PanelState?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let system = NSTextField(wrappingLabelWithString: "")
    private let keep = NSSwitch()
    private let keepIcon = NSImageView()
    private let captureHint = NSTextField(wrappingLabelWithString: "")
    private let boostIcon = NSImageView()
    private let boost = NSSwitch()
    private let gain = NSSegmentedControl(labels: [L("panel_gain_low"), L("panel_gain_mid"), L("panel_gain_high")], trackingMode: .selectOne, target: nil, action: nil)
    private let route = NSTextField(wrappingLabelWithString: "")
    private let driver = NSTextField(wrappingLabelWithString: "")
    private let login = DeviceTile(PanelDevice(id: "login", name: L("launch_at_login"), enabled: true))
    private let restore = DeviceTile(PanelDevice(id: "restore", name: L("restore_on_launch"), enabled: true))
    private var retryButton: NSButton!
    private var installButton: NSButton!
    private var loginButton: NSButton!
    private let note = NSTextField(wrappingLabelWithString: "")
    private let noteGroup = NSStackView()
    private let startupGroup = NSStackView()
    private var contentStack: NSStackView!
    var resize: ((NSSize) -> Void)?
    private let scroll = NSScrollView()
    private var deviceSnapshot: [PanelDevice] = []

    private enum Action: Int { case keep, boost, retry, login, restore, help, boostHelp, install, recheck, loginSettings, quit, closeNote, virtualDevices }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 570))
        view.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let document = PanelDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView(); contentStack = stack
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)])
        func add(_ v: NSView) { stack.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let brand = label("KeepMicAlive", size: 16, weight: .semibold)
        let appIcon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        appIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [brand, status]); identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 2
        let header = NSStackView(views: [appIcon, identity]); header.spacing = 9; header.alignment = .centerY; add(header)

        bind(keep, .keep); keep.setAccessibilityLabel(L("panel_keep"))
        source.drawsBackground = false; source.hasVerticalScroller = true; source.autohidesScrollers = true
        source.setAccessibilityLabel(L("panel_microphone"))
        let deviceDocument = PanelDocument(); deviceDocument.translatesAutoresizingMaskIntoConstraints = false
        source.documentView = deviceDocument
        deviceStack.orientation = .vertical; deviceStack.spacing = 8; deviceStack.alignment = .leading
        deviceStack.translatesAutoresizingMaskIntoConstraints = false; deviceDocument.addSubview(deviceStack)
        deviceHeight = source.heightAnchor.constraint(equalToConstant: 52); deviceHeight.isActive = true
        NSLayoutConstraint.activate([deviceDocument.widthAnchor.constraint(equalTo: source.contentView.widthAnchor), deviceStack.leadingAnchor.constraint(equalTo: deviceDocument.leadingAnchor), deviceStack.trailingAnchor.constraint(equalTo: deviceDocument.trailingAnchor), deviceStack.topAnchor.constraint(equalTo: deviceDocument.topAnchor), deviceStack.bottomAnchor.constraint(equalTo: deviceDocument.bottomAnchor)])
        system.font = .systemFont(ofSize: 11); system.textColor = .secondaryLabelColor
        captureHint.font = .systemFont(ofSize: 11); captureHint.textColor = .secondaryLabelColor
        retryButton = button("panel_retry", .retry)
        virtualSource.drawsBackground = false
        virtualSource.hasVerticalScroller = true; virtualSource.autohidesScrollers = true
        let virtualDocument = PanelDocument(); virtualDocument.translatesAutoresizingMaskIntoConstraints = false
        virtualSource.documentView = virtualDocument
        virtualStack.orientation = .vertical; virtualStack.spacing = 8; virtualStack.alignment = .leading
        virtualStack.translatesAutoresizingMaskIntoConstraints = false; virtualDocument.addSubview(virtualStack)
        virtualHeight = virtualSource.heightAnchor.constraint(equalToConstant: 48); virtualHeight.isActive = true
        NSLayoutConstraint.activate([virtualDocument.widthAnchor.constraint(equalTo: virtualSource.contentView.widthAnchor), virtualStack.leadingAnchor.constraint(equalTo: virtualDocument.leadingAnchor), virtualStack.trailingAnchor.constraint(equalTo: virtualDocument.trailingAnchor), virtualStack.topAnchor.constraint(equalTo: virtualDocument.topAnchor), virtualStack.bottomAnchor.constraint(equalTo: virtualDocument.bottomAnchor)])
        let virtualIcon = NSImageView(image: NSImage(systemSymbolName: "waveform.path", accessibilityDescription: nil) ?? NSImage())
        virtualIcon.contentTintColor = .secondaryLabelColor
        virtualIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        virtualIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        virtualTitle = label("", size: 12, weight: .semibold)
        virtualButton = NSButton(title: "", target: nil, action: nil)
        bind(virtualButton, .virtualDevices)
        virtualButton.setButtonType(.momentaryPushIn); virtualButton.isBordered = false
        (virtualButton.cell as? NSButtonCell)?.showsStateBy = []
        virtualButton.imagePosition = .imageOnly; virtualButton.imageScaling = .scaleProportionallyDown
        virtualButton.contentTintColor = .controlAccentColor
        virtualButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        virtualButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        virtualButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        virtualHeader = NSStackView(views: [virtualIcon, virtualTitle, NSView(), virtualButton])
        virtualHeader.spacing = 8; virtualHeader.alignment = .centerY
        add(card([controlHeader(icon: keepIcon, symbol: "mic.fill", title: L("panel_keep"), subtitle: L("panel_keep_short"), control: keep), source, virtualHeader, virtualSource, system, captureHint, retryButton]))

        bind(boost, .boost); boost.setAccessibilityLabel(L("panel_boost"))
        gain.target = self; gain.action = #selector(selectGain); gain.setAccessibilityLabel(L("panel_gain"))
        route.font = .systemFont(ofSize: 11); route.textColor = .secondaryLabelColor
        driver.font = .systemFont(ofSize: 11); driver.textColor = .secondaryLabelColor
        installButton = button("panel_install", .install)
        let setup = NSStackView(views: [installButton, button("panel_recheck", .recheck), button("panel_test", .boostHelp)])
        setup.orientation = .horizontal; setup.spacing = 6
        add(card([controlHeader(icon: boostIcon, symbol: "waveform", title: L("panel_boost"), subtitle: L("panel_boost_short"), control: boost), gain, route, driver, setup]))

        startupGroup.orientation = .vertical; startupGroup.alignment = .leading; startupGroup.spacing = 10
        bind(login, .login); bind(restore, .restore)
        let loginSurface = deviceSurface(login), restoreSurface = deviceSurface(restore)
        let startupChoices = NSStackView(views: [loginSurface, restoreSurface])
        startupChoices.distribution = .fillEqually; startupChoices.spacing = 8
        loginSurface.widthAnchor.constraint(equalTo: restoreSurface.widthAnchor).isActive = true
        startupGroup.addArrangedSubview(startupChoices)
        startupGroup.addArrangedSubview(label(L("panel_restore_hint"), size: 11, secondary: true))
        loginButton = button("login_approval", .loginSettings); startupGroup.addArrangedSubview(loginButton)
        for child in startupGroup.arrangedSubviews { child.widthAnchor.constraint(equalTo: startupGroup.widthAnchor).isActive = true }
        let startupIcon = NSImageView()
        startupIcon.contentTintColor = .secondaryLabelColor
        add(card([controlHeader(icon: startupIcon, symbol: "power", title: L("panel_startup"), subtitle: L("panel_startup_short")), startupGroup]))
        let footer = NSStackView(views: [button("help", .help), NSView(), button("panel_quit", .quit)])
        footer.orientation = .horizontal; footer.spacing = 8; add(footer)
        noteGroup.orientation = .vertical; noteGroup.alignment = .leading; noteGroup.spacing = 8
        note.font = .systemFont(ofSize: 12); note.isSelectable = true; note.preferredMaxLayoutWidth = 352
        noteGroup.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: noteGroup.widthAnchor).isActive = true
        noteGroup.addArrangedSubview(button("panel_close_help", .closeNote)); add(noteGroup)
        noteGroup.isHidden = true
        for field in [status, system, route, driver, note, captureHint] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.preferredMaxLayoutWidth = 320
        return field
    }
    private func controlHeader(icon: NSImageView, symbol: String, title: String, subtitle: String, control: NSControl? = nil) -> NSView {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let text = NSStackView(views: [label(title, size: 13, weight: .semibold), label(subtitle, size: 11, secondary: true)])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let row = NSStackView(views: [icon, text, NSView()]); row.spacing = 8; row.alignment = .centerY
        if let control {
            row.addArrangedSubview(control)
            control.setContentHuggingPriority(.required, for: .horizontal)
        }
        return row
    }
    private func card(_ children: [NSView]) -> NSView {
        let content = NSView()
        let stack = NSStackView(views: children)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        for child in children { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        let shell: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 20; glass.contentView = content
            shell = glass
        } else {
            let material = NSVisualEffectView(); material.material = .popover; material.blendingMode = .withinWindow
            material.wantsLayer = true; material.layer?.cornerRadius = 18; material.layer?.masksToBounds = true
            material.addSubview(content); shell = material
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: shell.leadingAnchor), content.trailingAnchor.constraint(equalTo: shell.trailingAnchor), content.topAnchor.constraint(equalTo: shell.topAnchor), content.bottomAnchor.constraint(equalTo: shell.bottomAnchor)])
        return shell
    }
    private func fitPanel() {
        view.layoutSubtreeIfNeeded()
        let height = min(660, max(440, contentStack.fittingSize.height + 32))
        resize?(NSSize(width: 380, height: height))
    }
    private func bind(_ button: NSControl, _ action: Action) {
        button.tag = action.rawValue; button.target = self; button.action = #selector(act(_:))
        button.font = .systemFont(ofSize: 12)
    }
    private func button(_ key: String, _ action: Action) -> NSButton {
        let b = NSButton(title: L(key), target: nil, action: nil)
        b.bezelStyle = .rounded; b.controlSize = .small; bind(b, action); return b
    }
    @objc private func act(_ sender: NSControl) {
        guard let action = Action(rawValue: sender.tag) else { return }
        switch action {
        case .keep: toggleCapture?()
        case .boost: toggleEnhancement?()
        case .retry: retry?()
        case .login: toggleLogin?()
        case .restore: toggleRestore?()
        case .help: help?()
        case .boostHelp: enhancementHelp?()
        case .install: install?()
        case .recheck: recheck?()
        case .loginSettings: loginSettings?()
        case .quit: quit?()
        case .closeNote: noteGroup.isHidden = true; fitPanel()
        case .virtualDevices:
            showVirtual.toggle()
            if let latestState { updateDevices(latestState); fitPanel() }

        }
    }
    @objc private func selectSource(_ sender: DeviceTile) { chooseDevice?(sender.deviceID) }
    // Apply frequency ranking on opening, not under the pointer after a selection.
    func beginPresentation() { deviceSnapshot = [] }
    private func deviceSurface(_ tile: DeviceTile) -> NSView {
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.cornerRadius = 24; glass.style = .regular
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = tile
            tile.updateSurface = { [weak glass] selected in
                glass?.tintColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : nil
            }
            surface = glass
        } else {
            let material = NSVisualEffectView(); material.material = .popover; material.blendingMode = .withinWindow
            material.wantsLayer = true; material.layer?.cornerRadius = 22; material.layer?.masksToBounds = true
            material.addSubview(tile); surface = material
        }
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 6), tile.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6), tile.topAnchor.constraint(equalTo: surface.topAnchor), tile.bottomAnchor.constraint(equalTo: surface.bottomAnchor)])
        return surface
    }
    private func updateDevices(_ state: PanelState) {
        let incoming = Dictionary(uniqueKeysWithValues: state.devices.map { ($0.id, $0) })
        let previousIDs = Set(deviceSnapshot.map(\.id))
        let stable = deviceSnapshot.compactMap { incoming[$0.id] } + state.devices.filter { !previousIDs.contains($0.id) }
        let ordered = stable.filter { !$0.isVirtual } + stable.filter { $0.isVirtual }
        let virtualCount = ordered.filter(\.isVirtual).count
        virtualHeader.isHidden = virtualCount == 0
        virtualSource.isHidden = !showVirtual || virtualCount == 0
        virtualTitle.stringValue = L("panel_virtual", String(virtualCount))
        virtualSource.setAccessibilityLabel(virtualTitle.stringValue)
        virtualButton.state = showVirtual ? .on : .off
        virtualButton.setAccessibilityExpanded(showVirtual)
        let actionLabel = L(showVirtual ? "panel_virtual_collapse" : "panel_virtual_expand")
        virtualButton.setAccessibilityLabel(actionLabel)
        virtualButton.toolTip = actionLabel
        virtualButton.image = NSImage(systemSymbolName: showVirtual ? "chevron.up.circle.fill" : "chevron.down.circle.fill", accessibilityDescription: nil)
        source.isHidden = !ordered.contains(where: { !$0.isVirtual }) && virtualCount > 0
        let devices = ordered.filter { !$0.isVirtual || showVirtual }

        if tiles.map(\.deviceID) != devices.map(\.id) || tiles.map(\.deviceName) != devices.map(\.name) || (deviceStack.arrangedSubviews.isEmpty && virtualStack.arrangedSubviews.isEmpty) {
            for stack in [deviceStack, virtualStack] {
                for row in stack.arrangedSubviews { stack.removeArrangedSubview(row); row.removeFromSuperview() }
            }
            tiles = devices.map { device in
                let tile = DeviceTile(device); tile.target = self; tile.action = #selector(selectSource(_:)); return tile
            }
            let physical = tiles.filter { !$0.virtual }, virtual = tiles.filter { $0.virtual }
            func populate(_ group: [DeviceTile], in stack: NSStackView) {
                for index in stride(from: 0, to: group.count, by: 2) {
                    let left = deviceSurface(group[index])
                    let right: NSView = index + 1 < group.count ? deviceSurface(group[index + 1]) : NSView()
                    let row = NSStackView(views: [left, right]); row.distribution = .fillEqually; row.spacing = 8
                    left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
                    stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            populate(physical, in: deviceStack)
            populate(virtual, in: virtualStack)
            if devices.isEmpty && virtualCount == 0 {
                deviceStack.addArrangedSubview(label(L("none"), size: 12, secondary: true))
            }
            deviceHeight.constant = min(172, max(28, CGFloat((physical.count + 1) / 2) * 56 - 8))
            virtualHeight.constant = min(172, max(28, CGFloat((virtual.count + 1) / 2) * 56 - 8))
        }
        for (tile, device) in zip(tiles, devices) { tile.update(selected: device.id == state.selectedID, enabled: device.enabled && state.canToggle) }
        deviceSnapshot = ordered
    }
    @objc private func selectGain() {
        guard (0...2).contains(gain.selectedSegment) else { return }
        chooseGain?([6, 12, 18][gain.selectedSegment])
    }
    func update(_ state: PanelState) {
        _ = view
        if state.devices.first(where: { $0.id == state.selectedID })?.isVirtual == true && latestState?.selectedID != state.selectedID { showVirtual = true }
        latestState = state
        updateDevices(state)
        status.stringValue = state.status
        system.stringValue = L("system_input", state.systemName)
        system.isHidden = state.devices.first(where: { $0.id == state.selectedID })?.name == state.systemName
        captureHint.stringValue = L("boost_stopped_notice")
        captureHint.isHidden = !state.boostStoppedNotice
        keepIcon.contentTintColor = state.requested ? .controlAccentColor : .secondaryLabelColor
        boostIcon.contentTintColor = state.enhancement ? .systemPurple : .secondaryLabelColor
        keep.state = state.requested ? .on : .off; keep.isEnabled = state.canToggle && (state.requested || !state.devices.isEmpty)
        boost.state = state.enhancement ? .on : .off
        boost.isEnabled = state.canToggle && (state.driverInstalled || state.enhancement)
        gain.selectedSegment = [Float(6), 12, 18].firstIndex(of: state.gain) ?? 1
        gain.isEnabled = state.enhancement
        driver.stringValue = L(state.driverInstalled ? "panel_driver_ready" : "panel_driver_missing")
        installButton.isHidden = state.driverInstalled
        route.stringValue = L(state.enhancement ? (state.sending ? "panel_route_active" : "panel_route_pending") : "panel_route_off")
        retryButton.isEnabled = state.canRetry
        login.update(selected: state.loginState == .on, enabled: true, uncheckedSymbol: "circle")
        if state.loginState == .mixed {
            login.state = .mixed
            login.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
            login.setAccessibilityValue(2)
        }
        restore.update(selected: state.restore, enabled: true, uncheckedSymbol: "circle")
        loginButton.isHidden = !state.loginPending
        fitPanel()
    }
    func showNotice(_ text: String) {
        _ = view
        note.stringValue = text; noteGroup.isHidden = false
        fitPanel()
        noteGroup.scrollToVisible(noteGroup.bounds)
    }
    static func runTests() {
        _ = NSApplication.shared
        let panel = ControlPanel()
        var state = PanelState(devices: [], selectedID: nil, systemName: "None", status: "Stopped", requested: false, canToggle: true, enhancement: false, gain: 12, driverInstalled: false, sending: false, canRetry: false, loginState: .off, loginPending: false, restore: false)
        panel.update(state)
        assert(!panel.boost.isEnabled && !panel.installButton.isHidden)
        assert(!panel.keep.isEnabled && panel.tiles.isEmpty)
        state.devices = [PanelDevice(id: "mic", name: "Test microphone", enabled: true)]
        state.selectedID = "mic"; state.driverInstalled = true
        panel.update(state)
        assert(panel.boost.isEnabled && panel.installButton.isHidden && panel.keep.isEnabled)
        assert(panel.tiles.first?.deviceID == "mic" && panel.tiles.first?.state == .on)
        state.devices.append(PanelDevice(id: "second", name: "Another microphone", enabled: true))
        panel.update(state)
        state.devices.reverse(); state.selectedID = "second"
        panel.update(state)
        assert(panel.tiles.map(\.deviceID) == ["mic", "second"]) // Stable during clicks.
        panel.beginPresentation(); panel.update(state)
        assert(panel.tiles.map(\.deviceID) == ["second", "mic"])
        state.devices.insert(PanelDevice(id: "virtual", name: "Virtual input", enabled: true, isVirtual: true), at: 0)
        panel.beginPresentation(); panel.update(state)
        assert(panel.tiles.map(\.deviceID) == ["second", "mic"])
        assert(!panel.virtualHeader.isHidden && panel.virtualSource.isHidden)
        panel.virtualButton.performClick(nil)
        assert(panel.showVirtual && !panel.virtualSource.isHidden && panel.virtualButton.state == .on)
        assert(panel.tiles.map(\.deviceID) == ["second", "mic", "virtual"])
        panel.virtualButton.performClick(nil)
        assert(!panel.showVirtual && panel.virtualSource.isHidden && panel.virtualButton.state == .off)
        state.selectedID = "virtual"; panel.update(state)
        assert(panel.showVirtual && !panel.virtualSource.isHidden)
        state.enhancement = true; state.requested = true; state.sending = true; state.gain = 18
        panel.update(state)
        assert(panel.gain.isEnabled && panel.gain.selectedSegment == 2)
        assert(panel.keep.state == .on && panel.boost.state == .on)
        state.requested = false; state.enhancement = false; state.boostStoppedNotice = true
        panel.update(state)
        assert(panel.keep.state == .off && panel.boost.state == .off)
        assert(!panel.captureHint.isHidden)
        state.enhancement = true; state.requested = true; state.boostStoppedNotice = false
        panel.update(state)
        assert(panel.captureHint.isHidden)
        panel.showNotice("Test guidance")
        assert(!panel.noteGroup.isHidden)
        assert(!panel.startupGroup.isHidden)
        state.loginState = .on; state.restore = true
        panel.update(state)
        assert(panel.login.state == .on && panel.restore.state == .on)
        panel.showNotice(String(repeating: "Long guidance that must wrap inside a fixed width. ", count: 30))
        panel.view.layoutSubtreeIfNeeded()
        assert(abs(panel.view.fittingSize.width - 380) < 1)
        assert(abs(panel.view.frame.width - 380) < 1)
        state.driverInstalled = false
        panel.update(state)
        assert(panel.boost.isEnabled) // An unavailable driver must not prevent switching boost off.
        print("PASS: panel missing-driver setup, device selection, gain states and inline help")
    }

}
