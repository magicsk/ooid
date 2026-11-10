import AppKit

// Proper settings window. Separate from the in-shader "Tune" panel so it can
// be opened from the menu bar even when the main window is hidden.
final class SettingsController: NSObject, NSWindowDelegate {

    // Callbacks — AppDelegate wires these up to persist to UserDefaults and
    // reconfigure the idle monitor / menu-bar item.
    var onAutoScreensaverToggled: ((Bool) -> Void)?
    var onTimeoutMinutesChanged: ((Double) -> Void)?
    var onShowInMenuBarToggled: ((Bool) -> Void)?
    var onHotCornerChanged: ((Int) -> Void)?
    var onFrameRateChanged: ((Int) -> Void)?
    var onIdleThrottleToggled: ((Bool) -> Void)?

    // Frame-rate options. 30 is the GPU-friendly default; 60 is standard
    // smooth; 120 unlocks ProMotion for users who want maximum fluidity.
    static let frameRateOptions: [Int] = [30, 60, 120]

    private var window: NSWindow?

    // Controls
    private let autoEnableCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let timeoutSlider = NSSlider(value: 5, minValue: 1, maxValue: 30, target: nil, action: nil)
    private let timeoutValue  = NSTextField(labelWithString: "5 min")
    private let showInMenuBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hotCornerPopup = NSPopUpButton(title: "", target: nil, action: nil)
    private let frameRatePopup = NSPopUpButton(title: "", target: nil, action: nil)
    private let idleThrottleCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    func show(autoEnabled: Bool, minutes: Double, showInMenuBar: Bool, hotCorner: Int,
              frameRate: Int, idleThrottle: Bool) {
        buildWindowIfNeeded()
        autoEnableCheckbox.state = autoEnabled ? .on : .off
        timeoutSlider.doubleValue = minutes
        timeoutValue.stringValue = "\(Int(round(minutes))) min"
        showInMenuBarCheckbox.state = showInMenuBar ? .on : .off
        hotCornerPopup.selectItem(at: hotCorner)
        selectFrameRate(frameRate)
        idleThrottleCheckbox.state = idleThrottle ? .on : .off
        refreshEnabledStates()

        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func selectFrameRate(_ fps: Int) {
        let idx = Self.frameRateOptions.firstIndex(of: fps) ?? 0
        frameRatePopup.selectItem(at: idx)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self

        // ---- Screensaver section ----
        let ssHeader = sectionHeader("Screensaver")

        autoEnableCheckbox.title = "Start screensaver automatically when idle"
        autoEnableCheckbox.target = self
        autoEnableCheckbox.action = #selector(autoEnableChanged(_:))

        let timeoutLabel = NSTextField(labelWithString: "Timeout")
        timeoutLabel.font = NSFont.systemFont(ofSize: 12)
        timeoutLabel.textColor = .secondaryLabelColor

        timeoutValue.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeoutValue.alignment = .right

        timeoutSlider.isContinuous = true
        timeoutSlider.allowsTickMarkValuesOnly = true
        timeoutSlider.numberOfTickMarks = 30
        timeoutSlider.target = self
        timeoutSlider.action = #selector(timeoutSliderChanged(_:))
        timeoutSlider.translatesAutoresizingMaskIntoConstraints = false
        timeoutSlider.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let timeoutHeader = NSStackView(views: [timeoutLabel, timeoutValue])
        timeoutHeader.orientation = .horizontal
        timeoutHeader.distribution = .equalSpacing
        timeoutHeader.translatesAutoresizingMaskIntoConstraints = false
        timeoutHeader.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let timeoutRow = NSStackView(views: [timeoutHeader, timeoutSlider])
        timeoutRow.orientation = .vertical
        timeoutRow.alignment = .leading
        timeoutRow.spacing = 4

        let note = NSTextField(labelWithString: "Won't start while another app is keeping the display awake (video playback, presentations).")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = 380

        // Hot-corner picker — shove the cursor into a corner to trigger
        // the screensaver instantly (dwell ~350 ms, auto-re-arms on leave).
        let hotCornerLabel = NSTextField(labelWithString: "Hot corner")
        hotCornerLabel.font = NSFont.systemFont(ofSize: 12)
        hotCornerLabel.textColor = .secondaryLabelColor
        hotCornerPopup.removeAllItems()
        hotCornerPopup.addItems(withTitles: ["None", "Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right"])
        hotCornerPopup.target = self
        hotCornerPopup.action = #selector(hotCornerChanged(_:))
        hotCornerPopup.translatesAutoresizingMaskIntoConstraints = false
        hotCornerPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let hotCornerRow = NSStackView(views: [hotCornerLabel, hotCornerPopup])
        hotCornerRow.orientation = .horizontal
        hotCornerRow.spacing = 10
        hotCornerRow.alignment = .firstBaseline

        let screensaver = NSStackView(views: [ssHeader, autoEnableCheckbox, timeoutRow, hotCornerRow, note])
        screensaver.orientation = .vertical
        screensaver.alignment = .leading
        screensaver.spacing = 10

        // ---- General section ----
        let generalHeader = sectionHeader("General")

        showInMenuBarCheckbox.title = "Show in menu bar"
        showInMenuBarCheckbox.target = self
        showInMenuBarCheckbox.action = #selector(showInMenuBarChanged(_:))

        let menuBarNote = NSTextField(labelWithString: "When enabled, closing the window hides the dock icon instead of quitting — the app stays running and accessible from the menu bar.")
        menuBarNote.font = NSFont.systemFont(ofSize: 11)
        menuBarNote.textColor = .tertiaryLabelColor
        menuBarNote.maximumNumberOfLines = 3
        menuBarNote.preferredMaxLayoutWidth = 380

        // Frame-rate popup. 30 is the GPU-minimising default; users with
        // ProMotion displays or a preference for smoother motion can raise
        // it here. Idle rate (when nothing's interacting) stays at 15 fps
        // regardless — the GPU only spins fast when something's moving.
        let frameRateLabel = NSTextField(labelWithString: "Frame rate")
        frameRateLabel.font = NSFont.systemFont(ofSize: 12)
        frameRateLabel.textColor = .secondaryLabelColor
        frameRatePopup.removeAllItems()
        frameRatePopup.addItems(withTitles: Self.frameRateOptions.map { "\($0) fps" })
        frameRatePopup.target = self
        frameRatePopup.action = #selector(frameRateChanged(_:))
        frameRatePopup.translatesAutoresizingMaskIntoConstraints = false
        frameRatePopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let frameRateRow = NSStackView(views: [frameRateLabel, frameRatePopup])
        frameRateRow.orientation = .horizontal
        frameRateRow.spacing = 10
        frameRateRow.alignment = .firstBaseline

        let frameRateNote = NSTextField(labelWithString: "Higher rates look smoother but use more GPU.")
        frameRateNote.font = NSFont.systemFont(ofSize: 11)
        frameRateNote.textColor = .tertiaryLabelColor
        frameRateNote.maximumNumberOfLines = 2
        frameRateNote.preferredMaxLayoutWidth = 380

        idleThrottleCheckbox.title = "Reduce to 15 fps when idle"
        idleThrottleCheckbox.target = self
        idleThrottleCheckbox.action = #selector(idleThrottleChanged(_:))

        let idleThrottleNote = NSTextField(labelWithString: "Saves GPU when the shader is animating on its own. Turn off for perfectly steady motion at the chosen frame rate.")
        idleThrottleNote.font = NSFont.systemFont(ofSize: 11)
        idleThrottleNote.textColor = .tertiaryLabelColor
        idleThrottleNote.maximumNumberOfLines = 3
        idleThrottleNote.preferredMaxLayoutWidth = 380

        let general = NSStackView(views: [generalHeader, showInMenuBarCheckbox, menuBarNote,
                                          frameRateRow, frameRateNote,
                                          idleThrottleCheckbox, idleThrottleNote])
        general.orientation = .vertical
        general.alignment = .leading
        general.spacing = 10

        // ---- Root layout ----
        let root = NSStackView(views: [screensaver, divider(), general])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        w.contentView = content
        window = w
    }

    private func sectionHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return label
    }
    private func divider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 412).isActive = true
        return v
    }

    private func refreshEnabledStates() {
        let on = autoEnableCheckbox.state == .on
        timeoutSlider.isEnabled = on
        timeoutValue.textColor = on ? .labelColor : .tertiaryLabelColor
    }

    @objc private func autoEnableChanged(_ sender: NSButton) {
        refreshEnabledStates()
        onAutoScreensaverToggled?(sender.state == .on)
    }
    @objc private func timeoutSliderChanged(_ sender: NSSlider) {
        let m = round(sender.doubleValue)
        timeoutValue.stringValue = "\(Int(m)) min"
        onTimeoutMinutesChanged?(m)
    }
    @objc private func showInMenuBarChanged(_ sender: NSButton) {
        onShowInMenuBarToggled?(sender.state == .on)
    }
    @objc private func hotCornerChanged(_ sender: NSPopUpButton) {
        onHotCornerChanged?(sender.indexOfSelectedItem)
    }
    @objc private func frameRateChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < Self.frameRateOptions.count else { return }
        onFrameRateChanged?(Self.frameRateOptions[idx])
    }
    @objc private func idleThrottleChanged(_ sender: NSButton) {
        onIdleThrottleToggled?(sender.state == .on)
    }
}
