import AppKit
import Metal
import MetalKit
import IOKit
import IOKit.pwr_mgt
import Sparkle

// Borderless windows don't accept keyboard focus by default. This subclass
// lets the window still own keyboard focus in wallpaper mode.
final class AppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: AppWindow!
    private var metalView: MetalContentView!
    private var overlay: OverlayView!
    private var renderer: Renderer!
    private var overlayTimer: Timer?
    private let settingsController = SettingsController()
    private var statusItem: NSStatusItem?
    // Only the packaged .app has the Info.plist keys Sparkle needs; under
    // `swift run` it would show a startup error instead.
    private let updater: SPUStandardUpdaterController? = Bundle.main.bundleURL.pathExtension == "app"
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        : nil
    // Track whether the window was hidden (menu-bar mode) when we entered a
    // fullscreen mode — so we know to re-hide it on exit.
    private var shouldRehideOnModeExit = false

    // Mode state — wallpaper (behind apps) and screensaver (above everything)
    // are mutually exclusive. We snapshot the window's normal-mode state on
    // entry so restoring is a single assignment back.
    private enum PresentationMode { case normal, wallpaper, screensaver }
    private var mode: PresentationMode = .normal
    private var savedFrame: NSRect = .zero
    private var savedStyleMask: NSWindow.StyleMask = []
    private var savedLevel: NSWindow.Level = .normal
    private var savedCollectionBehavior: NSWindow.CollectionBehavior = []

    // Auto-screensaver settings — persisted via UserDefaults so the app
    // behaves like a real screensaver replacement across launches.
    private struct Defaults {
        static let autoScreensaverEnabled = "autoScreensaverEnabled"
        static let autoScreensaverMinutes = "autoScreensaverMinutes"
        static let mouseEffectsEnabled    = "mouseEffectsEnabled"
        static let showInMenuBar          = "showInMenuBar"
        static let hotCorner              = "hotCorner"
        static let maxFrameRate           = "maxFrameRate"
        static let idleThrottleEnabled    = "idleThrottleEnabled"
    }

    // Hot-corner enum. 0 = disabled, 1–4 = the four corners. Persisted as Int.
    enum HotCorner: Int {
        case none = 0
        case topLeft = 1
        case topRight = 2
        case bottomLeft = 3
        case bottomRight = 4
    }
    private var autoScreensaverEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Defaults.autoScreensaverEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.autoScreensaverEnabled) }
    }
    private var autoScreensaverMinutes: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Defaults.autoScreensaverMinutes)
            return v > 0 ? v : 5.0
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.autoScreensaverMinutes) }
    }
    private var showInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: Defaults.showInMenuBar) }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.showInMenuBar) }
    }
    private var hotCorner: HotCorner {
        get { HotCorner(rawValue: UserDefaults.standard.integer(forKey: Defaults.hotCorner)) ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Defaults.hotCorner) }
    }
    private var maxFrameRate: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Defaults.maxFrameRate)
            // 0 means "unset" — use the default. Also guard against stale
            // values by snapping to the nearest supported option.
            let opts = SettingsController.frameRateOptions
            if opts.contains(v) { return v }
            return 30
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.maxFrameRate) }
    }
    private var idleThrottleEnabled: Bool {
        get {
            // Default is ON. UserDefaults.bool returns false for unset keys,
            // so check for explicit presence before trusting the value.
            if UserDefaults.standard.object(forKey: Defaults.idleThrottleEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Defaults.idleThrottleEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.idleThrottleEnabled) }
    }
    private var idleCheckTimer: Timer?
    // Hot-corner dwell tracking. `hotCornerEnteredAt` timestamps when the
    // cursor first entered the active corner; after `hotCornerDwell` seconds
    // the screensaver fires. `hotCornerArmed` prevents re-triggering while
    // the cursor is still in the corner — user must leave and re-enter.
    private var hotCornerEnteredAt: CFTimeInterval?
    private var hotCornerArmed: Bool = true
    private let hotCornerDwell: CFTimeInterval = 0.35
    private let hotCornerThreshold: CGFloat = 3.0


    func applicationDidFinishLaunching(_ note: Notification) {
        // Prefer the default system GPU — on Apple silicon this is the unified integrated GPU
        // which has near-zero copy cost for uniforms. On discrete Macs it's the best available.
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSApp.presentError(NSError(domain: "Ooid", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this Mac."]))
            NSApp.terminate(nil); return
        }

        // Dock / App Switcher icon. On macOS 26+ (Tahoe) NSImage reads the
        // native `.icon` package and the system applies its live material /
        // glass / parallax treatment. On older systems that returns nil, so
        // we fall back to a pre-Tahoe 1024² PNG (rounded corners + shadow
        // baked in) bundled alongside it.
        var appIcon: NSImage?
        if let iconURL = AppResources.url(forResource: "AppIcon", withExtension: "icon")
            ?? AppResources.url(forResource: "wallpaper", withExtension: "icon") {
            appIcon = NSImage(contentsOf: iconURL)
        }
        if appIcon == nil,
           let pngURL = AppResources.url(forResource: "AppIcon", withExtension: "png") {
            appIcon = NSImage(contentsOf: pngURL)
        }
        if let icon = appIcon { NSApp.applicationIconImage = icon }

        do {
            renderer = try Renderer(device: device)
        } catch {
            NSApp.presentError(error)
            NSApp.terminate(nil); return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let rect = NSRect(x: 0, y: 0, width: min(size.width, 1400), height: min(size.height, 900))

        window = AppWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        window.title = "Ooid"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 9/255, green: 9/255, blue: 10/255, alpha: 1)
        window.center()

        // Content: Metal view fills the content, overlay sits on top.
        let contentRect = NSRect(origin: .zero, size: rect.size)
        let content = NSView(frame: contentRect)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = window.backgroundColor?.cgColor

        metalView = MetalContentView(renderer: renderer, frame: contentRect)
        metalView.autoresizingMask = [.width, .height]
        content.addSubview(metalView)

        overlay = OverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        overlay.onSelect = { [weak self] idx in self?.renderer.selectShader(idx) }
        overlay.onToggleWallpaper   = { [weak self] in self?.toggleWallpaperMode() }
        overlay.onToggleScreensaver = { [weak self] in self?.toggleScreensaverMode() }
        overlay.onOptionChanged = { [weak self] slot, value in
            guard let self = self else { return }
            self.renderer.setOption(shaderIndex: self.renderer.currentShaderIndex, slot: slot, value: value)
        }
        overlay.onMouseEffectsToggled = { [weak self] enabled in
            guard let self = self else { return }
            self.renderer.mouseEffectsEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Defaults.mouseEffectsEnabled)
        }
        overlay.onOpenSettings = { [weak self] in self?.openSettings() }
        overlay.onColorChanged = { [weak self] slot, value in
            guard let self = self else { return }
            self.renderer.setColor(shaderIndex: self.renderer.currentShaderIndex, slot: slot, value: value)
        }
        overlay.onColorPresetApplied = { [weak self] cs in
            guard let self = self else { return }
            self.renderer.setColorSet(shaderIndex: self.renderer.currentShaderIndex, cs)
        }

        // Settings callbacks.
        settingsController.onAutoScreensaverToggled = { [weak self] enabled in
            self?.autoScreensaverEnabled = enabled
        }
        settingsController.onTimeoutMinutesChanged = { [weak self] minutes in
            self?.autoScreensaverMinutes = minutes
        }
        settingsController.onShowInMenuBarToggled = { [weak self] enabled in
            self?.setShowInMenuBar(enabled)
        }
        settingsController.onHotCornerChanged = { [weak self] rawValue in
            guard let self = self else { return }
            self.hotCorner = HotCorner(rawValue: rawValue) ?? .none
            // Reset dwell state so a stale value from before the change
            // doesn't immediately trigger.
            self.hotCornerEnteredAt = nil
            self.hotCornerArmed = true
        }
        settingsController.onFrameRateChanged = { [weak self] fps in
            guard let self = self else { return }
            self.maxFrameRate = fps
            self.metalView.setActiveFps(fps)
        }
        settingsController.onIdleThrottleToggled = { [weak self] enabled in
            guard let self = self else { return }
            self.idleThrottleEnabled = enabled
            self.metalView.setIdleThrottleEnabled(enabled)
        }
        renderer.onShaderChange = { [weak self] idx in
            guard let self = self else { return }
            self.refreshOverlay(index: idx)
            self.metalView.onShaderChanged()
            self.overlay.applyOptionValues(
                self.renderer.optionValue(for: idx),
                mouseEffectsEnabled: self.renderer.mouseEffectsEnabled)
            self.overlay.applyColorSet(self.renderer.colorSet(for: idx))
        }
        metalView.onRequestWallpaperToggle   = { [weak self] in self?.toggleWallpaperMode() }
        metalView.onRequestScreensaverToggle = { [weak self] in self?.toggleScreensaverMode() }
        metalView.onRequestWallpaperExit = { [weak self] in
            if self?.mode == .wallpaper { self?.toggleWallpaperMode() }
        }
        metalView.onRequestScreensaverExit = { [weak self] in
            if self?.mode == .screensaver { self?.toggleScreensaverMode() }
        }

        window.contentView = content
        window.delegate = self
        window.makeFirstResponder(metalView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Restore persisted settings.
        if UserDefaults.standard.object(forKey: Defaults.mouseEffectsEnabled) != nil {
            renderer.mouseEffectsEnabled = UserDefaults.standard.bool(forKey: Defaults.mouseEffectsEnabled)
        }
        metalView.setActiveFps(maxFrameRate)
        metalView.setIdleThrottleEnabled(idleThrottleEnabled)

        refreshOverlay(index: renderer.currentShaderIndex)
        overlay.applyOptionValues(
            renderer.optionValue(for: renderer.currentShaderIndex),
            mouseEffectsEnabled: renderer.mouseEffectsEnabled)
        overlay.applyColorSet(renderer.colorSet(for: renderer.currentShaderIndex))

        if showInMenuBar { installStatusItem() }
        startIdleMonitor()

        // 10 Hz UI tick updates the coord/intensity readouts without pulling into the render loop.
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            self?.overlay.render(index: self!.renderer.currentShaderIndex,
                                 coord: self!.renderer.coord,
                                 intensity: self!.renderer.intensity)
        }
        RunLoop.main.add(overlayTimer!, forMode: .common)

        installMenu()
    }

    private func refreshOverlay(index: Int) {
        overlay.render(index: index, coord: renderer.coord, intensity: renderer.intensity)
    }

    // Wallpaper mode: drop the window onto the desktop layer (behind all
    // app windows, in front of the system wallpaper, behind desktop icons).
    // Clicks on blank desktop still reach us; clicks on icons go to Finder.
    func toggleWallpaperMode() {
        if mode == .screensaver { exitScreensaverMode() }
        if mode == .wallpaper {
            exitWallpaperMode()
        } else {
            enterWallpaperMode()
        }
    }

    // Screensaver mode: raise the window to .screenSaver level (above every-
    // thing), cover the screen, hide cursor, auto-cycle shaders. Click or
    // key press exits.
    func toggleScreensaverMode() {
        if mode == .wallpaper { exitWallpaperMode() }
        if mode == .screensaver {
            exitScreensaverMode()
        } else {
            enterScreensaverMode()
        }
    }

    private func snapshotWindowState() {
        savedFrame = window.frame
        savedStyleMask = window.styleMask
        savedLevel = window.level
        savedCollectionBehavior = window.collectionBehavior
    }
    private func restoreWindowState() {
        window.styleMask = savedStyleMask
        window.level = savedLevel
        window.collectionBehavior = savedCollectionBehavior
        window.setFrame(savedFrame, display: true)
        window.isMovable = true
        window.hasShadow = true
    }
    private func expandToScreen() {
        window.styleMask = [.borderless, .fullSizeContentView]
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.frame, display: true)
        }
        window.isMovable = false
        window.hasShadow = false
    }

    private func enterWallpaperMode() {
        snapshotWindowState()
        expandToScreen()
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        overlay.setChromeHidden(true)
        metalView.setWallpaperMode(true)
        window.makeFirstResponder(metalView)
        mode = .wallpaper
    }
    private func exitWallpaperMode() {
        metalView.setWallpaperMode(false)
        overlay.setChromeHidden(false)
        restoreWindowState()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(metalView)
        mode = .normal
    }

    private func enterScreensaverMode() {
        // Normal-screensaver behaviour: keep the currently chosen shader,
        // hide the cursor, and let the MetalContentView's auto-pilot drive
        // the "mouse" from the first frame.
        snapshotWindowState()
        expandToScreen()
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        overlay.setChromeHidden(true)
        metalView.setScreensaverMode(true)

        // Fade in. Start at 0 alpha, then animate to full opacity so the
        // transition from desktop → screensaver is smooth.
        window.alphaValue = 0.0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(metalView)
        NSCursor.hide()
        mode = .screensaver

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.window.animator().alphaValue = 1.0
        }
    }
    private func exitScreensaverMode() {
        guard mode == .screensaver else { return }

        // Mark us out of screensaver mode immediately so the 30 Hz auto-
        // pilot stops driving the shader and rapid-fire exit events become
        // no-ops during the fade-out.
        mode = .normal
        metalView.setScreensaverMode(false)
        NSCursor.unhide()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.window.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.finishScreensaverExit()
        })
    }
    private func finishScreensaverExit() {
        overlay.setChromeHidden(false)
        restoreWindowState()
        window.makeFirstResponder(metalView)
        window.alphaValue = 1.0

        if shouldRehideOnModeExit {
            shouldRehideOnModeExit = false
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // Combined periodic check — tests both the global idle timer (for
    // auto-screensaver) and the hot-corner cursor position. 0.3 s cadence
    // is fast enough for hot-corner dwell detection (~350 ms trigger) and
    // still cheap: two IOKit/NSEvent lookups and a bit of math.
    private func startIdleMonitor() {
        idleCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkIdle()
            self?.checkHotCorner()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleCheckTimer = timer
    }
    private func checkIdle() {
        guard autoScreensaverEnabled, mode == .normal else { return }
        // Don't fire while another process is keeping the display awake
        // (video playback, presentations, screen share, etc. — the same
        // signal the macOS screensaver uses).
        if isDisplaySleepPrevented() { return }
        let anyEvent = CGEventType(rawValue: ~0)!
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyEvent)
        if idleSeconds >= autoScreensaverMinutes * 60 {
            // If we're in menu-bar mode with the window hidden, bring the
            // window up so the screensaver has something to render on.
            if !window.isVisible {
                shouldRehideOnModeExit = true
                NSApp.setActivationPolicy(.regular)
                window.makeKeyAndOrderFront(nil)
            }
            enterScreensaverMode()
        }
    }

    // Hot-corner check. Fires screensaver when the cursor dwells in the
    // user-selected corner of any attached display. Requires a short dwell
    // so passing-through doesn't trigger. Re-arms only after the cursor
    // leaves the corner.
    private func checkHotCorner() {
        guard hotCorner != .none, mode == .normal else {
            hotCornerEnteredAt = nil
            hotCornerArmed = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let inCorner = NSScreen.screens.contains {
            isMouse(mouse, inCorner: hotCorner, of: $0)
        }

        if !inCorner {
            hotCornerEnteredAt = nil
            hotCornerArmed = true
            return
        }
        guard hotCornerArmed else { return }
        if hotCornerEnteredAt == nil {
            hotCornerEnteredAt = CACurrentMediaTime()
            return
        }
        if CACurrentMediaTime() - hotCornerEnteredAt! >= hotCornerDwell {
            hotCornerEnteredAt = nil
            hotCornerArmed = false  // stays unarmed until cursor leaves corner

            // If we're in menu-bar accessory mode with the window hidden,
            // bring it back before the screensaver claims the display.
            if !window.isVisible {
                shouldRehideOnModeExit = true
                NSApp.setActivationPolicy(.regular)
                window.makeKeyAndOrderFront(nil)
            }
            enterScreensaverMode()
        }
    }
    private func isMouse(_ p: NSPoint, inCorner corner: HotCorner, of screen: NSScreen) -> Bool {
        let f = screen.frame
        let t = hotCornerThreshold
        switch corner {
        case .none: return false
        case .topLeft:     return p.x <= f.minX + t && p.y >= f.maxY - t
        case .topRight:    return p.x >= f.maxX - t && p.y >= f.maxY - t
        case .bottomLeft:  return p.x <= f.minX + t && p.y <= f.minY + t
        case .bottomRight: return p.x >= f.maxX - t && p.y <= f.minY + t
        }
    }

    // Returns true if any process currently holds a PreventUserIdleDisplay-
    // Sleep assertion — e.g. a video playing in Safari / VLC / QuickTime,
    // or a Keynote presentation.
    private func isDisplaySleepPrevented() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let ns = dict?.takeRetainedValue() as NSDictionary?
        else { return false }
        for value in ns.allValues {
            guard let list = value as? [[String: Any]] else { continue }
            for props in list {
                guard
                    let type = props["AssertType"] as? String,
                    let level = props["AssertLevel"] as? Int, level > 0
                else { continue }
                if type == "PreventUserIdleDisplaySleep" ||
                   type == "NoDisplaySleepAssertion" {
                    return true
                }
            }
        }
        return false
    }

    // ---------------- Settings window ----------------
    private func openSettings() {
        settingsController.show(
            autoEnabled: autoScreensaverEnabled,
            minutes: autoScreensaverMinutes,
            showInMenuBar: showInMenuBar,
            hotCorner: hotCorner.rawValue,
            frameRate: maxFrameRate,
            idleThrottle: idleThrottleEnabled)
    }
    @objc private func openSettingsAction(_ sender: Any?) { openSettings() }
    @objc private func checkForUpdatesAction(_ sender: Any?) { updater?.checkForUpdates(sender) }

    // ---------------- Menu bar item ----------------
    private func setShowInMenuBar(_ enabled: Bool) {
        showInMenuBar = enabled
        if enabled {
            installStatusItem()
        } else {
            removeStatusItem()
            // If the dock icon was hidden because the window was closed,
            // put it back so the user can reach the app normally.
            if !window.isVisible {
                NSApp.setActivationPolicy(.regular)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = makeOoidMenuBarIcon()
            icon.isTemplate = true
            icon.accessibilityDescription = "Ooid"
            button.image = icon
        }
        let menu = NSMenu()
        menu.addItem(itemTitle: "Start Screensaver", selector: #selector(menuStartScreensaver(_:)))
        menu.addItem(itemTitle: "Toggle Wallpaper Mode", selector: #selector(menuToggleWallpaper(_:)))
        menu.addItem(.separator())
        menu.addItem(itemTitle: "Show Window", selector: #selector(menuShowWindow(_:)))
        menu.addItem(itemTitle: "Settings…", selector: #selector(openSettingsAction(_:)), keyEquivalent: ",")
        if updater != nil {
            menu.addItem(itemTitle: "Check for Updates…", selector: #selector(checkForUpdatesAction(_:)))
        }
        menu.addItem(.separator())
        menu.addItem(itemTitle: "Quit Ooid", selector: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) {
            i.target = self
        }
        item.menu = menu
        statusItem = item
    }
    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // Template icon for the menu bar — three ellipses rotated 60° apart
    // form an interlocking knot reminiscent of the app icon silhouette.
    // Uses lockFocus (not the draw-on-demand closure form) so the resulting
    // bitmap rep has real alpha pixels that honour `isTemplate = true`.
    // Template mode lets macOS tint it for light/dark menu bars.
    private func makeOoidMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setStroke()
        let cx = size.width  * 0.5
        let cy = size.height * 0.5
        let rx = size.width  * 0.45
        let ry = size.height * 0.22
        for angle in [0.0, 60.0, 120.0] {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: cy)
            t.rotate(byDegrees: CGFloat(angle))
            t.concat()
            let path = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    @objc private func menuStartScreensaver(_ sender: Any?) {
        bringWindowToFrontIfHidden()
        if mode == .normal { enterScreensaverMode() }
    }
    @objc private func menuToggleWallpaper(_ sender: Any?) {
        bringWindowToFrontIfHidden()
        toggleWallpaperMode()
    }
    @objc private func menuShowWindow(_ sender: Any?) {
        bringWindowToFrontIfHidden()
    }
    private func bringWindowToFrontIfHidden() {
        if !window.isVisible {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // ---------------- NSWindowDelegate ----------------
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if showInMenuBar {
            // Hide the window, drop to accessory mode so the dock icon
            // disappears. The status-item menu remains as the only way in.
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    // Don't auto-quit on close when running as a menu-bar utility.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !showInMenuBar
    }

    private func installMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Ooid",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        if updater != nil {
            appMenu.addItem(itemTitle: "Check for Updates…", selector: #selector(checkForUpdatesAction(_:))).target = self
        }
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettingsAction(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Toggle Full Screen",
                                   action: #selector(NSWindow.toggleFullScreen(_:)),
                                   keyEquivalent: "f"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

// Bootstrap: NSApplicationMain is not used because we're a pure SPM executable
// with no Info.plist. Build an NSApplication manually.
private extension NSMenu {
    @discardableResult
    func addItem(itemTitle: String, selector: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: itemTitle, action: selector, keyEquivalent: keyEquivalent)
        addItem(i)
        return i
    }
}

if CommandLine.arguments.contains("--bench") {
    let args = CommandLine.arguments
    do { try Bench.run(pngDir: args.firstIndex(of: "--png").map { args[$0 + 1] }) }
    catch { print(error); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
