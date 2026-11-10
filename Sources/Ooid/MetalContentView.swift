import AppKit
import MetalKit
import simd

// Root content view: hosts the MTKView and receives mouse/keyboard input.
// Subclassing MTKView keeps input tight and lets us opt out of the view's
// automatic resume/pause behaviour precisely when we want.
final class MetalContentView: MTKView {

    let renderer: Renderer
    private var trackingArea: NSTrackingArea?

    // Effective pixels per point, before the shader's own renderScale. Default
    // 1.0 — a quarter of a retina display's fragments; the fields are smooth
    // enough that the layer's bilinear upscale is hard to tell from native.
    // The '-' key drops quality (fewer fragments, cheaper) and '=' / '+'
    // raises it up to native.
    private let qualityLevels: [CGFloat] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private var qualityIndex = 2    // default = 1.0

    // Adaptive FPS tuned for wallpaper use: shaders are smooth analogue
    // animations that read fine at 30fps, and on ProMotion displays the
    // OS would otherwise happily feed us 120. When idle (no interaction,
    // no decaying click) we drop to 15fps — the motion is already slow.
    //
    // `activeFps` is user-configurable via Settings (30 / 60 / 120). Idle
    // stays pinned at 15 regardless — the point of idle is to be cheap.
    private var activeFps = 30
    private let idleFps   = 15
    private let idleAfter: CFTimeInterval = 1.2

    // When false, the view stays at `activeFps` whether or not the user is
    // interacting. Exposed as a Settings toggle for people who want
    // perfectly steady motion at the cost of a permanent GPU baseline.
    var idleThrottleEnabled: Bool = true
    private var lastInteractionAt: CFTimeInterval = CACurrentMediaTime()
    private var idleTimer: Timer?

    // Wallpaper-mode hooks — called from keyboard shortcuts.
    var onRequestWallpaperToggle:   (() -> Void)?
    var onRequestWallpaperExit:     (() -> Void)?
    var onRequestScreensaverToggle: (() -> Void)?
    var onRequestScreensaverExit:   (() -> Void)?

    private var isScreensaverMode = false

    // Screensaver auto-pilot: kicks in immediately on entering screensaver
    // mode (classic-screensaver behaviour — the program drives the view,
    // not the user). Clicks, keys, and any real mouse movement after a
    // short grace period exit.
    private var lastRealMouseAt: CFTimeInterval = CACurrentMediaTime()
    private var autoPilotActive = false
    private var autoPilotStartedAt: CFTimeInterval = 0
    private var nextAutoClickAt: CFTimeInterval = 0
    private var screensaverTimer: Timer?
    private var screensaverEnteredAt: CFTimeInterval = 0
    // Grace period after activation so the click that *triggered* the
    // screensaver doesn't immediately exit it on the cursor's settling move.
    private let screensaverGrace: CFTimeInterval = 1.2

    // Wallpaper-mode input plumbing. When the window drops to desktop level it
    // no longer becomes key on its own, so AppKit stops delivering mouseMoved
    // events to it. We cover both cases:
    //   * position:  a light timer polls NSEvent.mouseLocation each tick and
    //                converts screen coords to view-normalised coords;
    //   * clicks:    a local + global NSEvent monitor catches left-clicks
    //                whether or not our app is currently active.
    private var wallpaperPollTimer: Timer?
    private var wallpaperLocalMonitor: Any?
    private var wallpaperGlobalMonitor: Any?

    init(renderer: Renderer, frame: NSRect) {
        self.renderer = renderer
        super.init(frame: frame, device: renderer.device)

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        clearColor = MTLClearColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1.0)

        // Drive frames with the display, but let the OS pause us while occluded.
        // On ProMotion panels MTKView subdivides the 120Hz callback by
        // `preferredFramesPerSecond`, so 30fps here = 1-in-4 callbacks.
        preferredFramesPerSecond = activeFps
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = false    // we control drawable size ourselves
        presentsWithTransaction = false

        delegate = renderer
        wantsLayer = true
        layer?.isOpaque = true

        if let mtl = layer as? CAMetalLayer {
            mtl.displaySyncEnabled = true      // vsync
            mtl.maximumDrawableCount = 3       // triple-buffered swapchain
            mtl.magnificationFilter = .linear  // cheap bilinear upscale from low-res drawable
            mtl.minificationFilter  = .linear
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.evaluateIdleState()
        }
        RunLoop.main.add(idleTimer!, forMode: .common)
    }
    required init(coder: NSCoder) { fatalError() }

    // MARK: - Occlusion / visibility handling
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowMiniaturized),
            name: NSWindow.didMiniaturizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDeminiaturized),
            name: NSWindow.didDeminiaturizeNotification, object: window)
    }

    @objc private func windowOcclusionChanged() {
        guard let w = window else { return }
        let visible = w.occlusionState.contains(.visible)
        isPaused = !visible
    }
    @objc private func windowMiniaturized() { isPaused = true }
    @objc private func windowDeminiaturized() { isPaused = false }

    // MARK: - Resize / retina
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }
    override func layout() {
        super.layout()
        updateTrackingArea()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let backing = window?.backingScaleFactor ?? 2.0
        // renderScale is tuned for a 16" MBP screen (1728×1117 pt); bigger views
        // get proportionally fewer px/pt so the GPU cost per frame stays the same.
        // Never render above backing — more fragments than pixels is pure waste.
        let fit = min(1, (1728 * 1117 / max(1, bounds.width * bounds.height)).squareRoot())
        let effective = min(backing, qualityLevels[qualityIndex] * fit
            * ShaderCatalog.entries[renderer.currentShaderIndex].renderScale)
        let w = max(1, Int(bounds.width  * effective))
        let h = max(1, Int(bounds.height * effective))
        drawableSize = CGSize(width: w, height: h)
    }


    // Called from the AppDelegate when the user changes the Frame-rate
    // setting. Updates the active cap immediately; idle state will pick it
    // up on the next `evaluateIdleState` tick.
    func setActiveFps(_ fps: Int) {
        let clamped = max(15, min(240, fps))
        activeFps = clamped
        // Snap the live rate to the new cap if we're currently active; if
        // we're idle, `evaluateIdleState` already has us at `idleFps`.
        if preferredFramesPerSecond > clamped || preferredFramesPerSecond == idleFps {
            preferredFramesPerSecond = (CACurrentMediaTime() - lastInteractionAt > idleAfter) ? idleFps : clamped
        } else {
            preferredFramesPerSecond = clamped
        }
    }

    // MARK: - Idle detection / adaptive FPS
    private func noteInteraction() {
        lastInteractionAt = CACurrentMediaTime()
        if preferredFramesPerSecond != activeFps {
            preferredFramesPerSecond = activeFps
        }
    }
    private func evaluateIdleState() {
        let since = CACurrentMediaTime() - lastInteractionAt
        let idle = idleThrottleEnabled && since > idleAfter && renderer.clickStrength < 0.01
        let target = idle ? idleFps : activeFps
        if preferredFramesPerSecond != target {
            preferredFramesPerSecond = target
        }
    }

    // Called from AppDelegate when the user toggles "Reduce to 15 fps when
    // idle" in Settings. Flips the knob and immediately re-evaluates idle
    // state so the change takes effect without waiting for the 0.5s tick.
    func setIdleThrottleEnabled(_ enabled: Bool) {
        idleThrottleEnabled = enabled
        evaluateIdleState()
    }

    private func updateTrackingArea() {
        if let t = trackingArea { removeTrackingArea(t) }
        let opts: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let t = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: - Mouse
    override func mouseMoved(with event: NSEvent) {
        // Classic screensaver: any real mouse motion exits (after a brief
        // grace period so the activating click's cursor settling doesn't
        // immediately dismiss the screensaver).
        if isScreensaverMode {
            if CACurrentMediaTime() - screensaverEnteredAt > screensaverGrace {
                onRequestScreensaverExit?()
            }
            return
        }
        reportMouse(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if isScreensaverMode {
            if CACurrentMediaTime() - screensaverEnteredAt > screensaverGrace {
                onRequestScreensaverExit?()
            }
            return
        }
        reportMouse(event)
    }

    private func reportMouse(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // View y is bottom-up; the prototype uses 1 - e.clientY, i.e. also bottom-up.
        // So we just divide by bounds and pass straight through.
        let nx = Float(p.x / max(1, bounds.width))
        let ny = Float(p.y / max(1, bounds.height))
        renderer.updateMouseNormalized(SIMD2<Float>(nx, ny))
        noteInteraction()
        // Real user input — bump the screensaver idle timestamp so auto-pilot
        // releases control (if it had it) on the next tick.
        lastRealMouseAt = CACurrentMediaTime()
    }

    override func mouseDown(with event: NSEvent) {
        // In screensaver mode, a click exits — classic behavior.
        if isScreensaverMode { onRequestScreensaverExit?(); return }
        let p = convert(event.locationInWindow, from: nil)
        let nx = Float(p.x / max(1, bounds.width))
        let ny = Float(p.y / max(1, bounds.height))
        renderer.impulseClick(at: SIMD2<Float>(nx, ny))
        noteInteraction()
    }

    // MARK: - Keyboard
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        // Classic screensaver: any key press exits.
        if isScreensaverMode { onRequestScreensaverExit?(); return }

        guard let chars = event.charactersIgnoringModifiers else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 124: renderer.cycleShader(+1); noteInteraction(); return       // right arrow
        case 123: renderer.cycleShader(-1); noteInteraction(); return       // left arrow
        case 49:  renderer.cycleShader(+1); noteInteraction(); return       // space
        case 53:                                                             // esc: exit wallpaper mode if on, else toggle fullscreen
            if let exit = onRequestWallpaperExit { exit() } else { window?.toggleFullScreen(nil) }
            return
        default: break
        }
        if let ch = chars.first {
            switch ch {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let n = ch.wholeNumberValue { renderer.selectShader(n - 1) }
                noteInteraction(); return
            case "0":
                renderer.selectShader(9); noteInteraction(); return
            case "-", "_":
                qualityIndex = max(0, qualityIndex - 1); updateDrawableSize(); return
            case "=", "+":
                qualityIndex = min(qualityLevels.count - 1, qualityIndex + 1); updateDrawableSize(); return
            case "f", "F":
                window?.toggleFullScreen(nil); return
            case "w", "W":
                onRequestWallpaperToggle?(); return
            case "s", "S":
                onRequestScreensaverToggle?(); return
            case "q", "Q":
                NSApp.terminate(nil); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // Called by the renderer when the shader changes (since heavy shaders use
    // a different drawable scale).
    func onShaderChanged() { updateDrawableSize() }

    // MARK: - Wallpaper-mode input
    func setWallpaperMode(_ on: Bool) {
        if on { startWallpaperInput() } else { stopWallpaperInput() }
    }

    // Screensaver mode: classic behaviour — the program drives the shader
    // from the first frame, cursor is hidden, and any real input exits.
    func setScreensaverMode(_ on: Bool) {
        isScreensaverMode = on
        screensaverTimer?.invalidate()
        screensaverTimer = nil
        autoPilotActive = false

        if on {
            let now = CACurrentMediaTime()
            screensaverEnteredAt = now
            autoPilotActive = true
            autoPilotStartedAt = now
            // First synthesised click 4–8 s in — quick enough that the
            // screensaver feels alive, not quiet.
            nextAutoClickAt = now + Double.random(in: 4 ... 8)

            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.screensaverTick()
            }
            RunLoop.main.add(t, forMode: .common)
            screensaverTimer = t
        }
    }

    private func screensaverTick() {
        guard isScreensaverMode && autoPilotActive else { return }
        let now = CACurrentMediaTime()
        let pos = autoPilotPosition(at: now - autoPilotStartedAt)
        renderer.updateMouseNormalized(pos)

        if now >= nextAutoClickAt {
            renderer.impulseClick(at: pos)
            nextAutoClickAt = now + Double.random(in: 6 ... 12)
        }
    }

    // Sum of three sines per axis with incommensurate frequencies — no repeat
    // for any reasonable runtime, and naturally slow curves. Output is clamped
    // to 0.08–0.92 so we never hug the very edge (where most shaders lose
    // their interesting behaviour behind the vignette).
    private func autoPilotPosition(at t: CFTimeInterval) -> SIMD2<Float> {
        let td = t
        let x = 0.5
            + 0.26 * sin(td * 0.121)
            + 0.11 * sin(td * 0.293 + 1.3)
            + 0.04 * sin(td * 0.717 + 2.6)
        let y = 0.5
            + 0.24 * sin(td * 0.098 + 0.7)
            + 0.13 * cos(td * 0.214 + 0.5)
            + 0.04 * cos(td * 0.633 + 1.9)
        return SIMD2<Float>(
            Float(min(0.92, max(0.08, x))),
            Float(min(0.92, max(0.08, y)))
        )
    }

    private func startWallpaperInput() {
        stopWallpaperInput()

        // Poll the global cursor at the display's current cadence (~60 Hz).
        // It's cheap — one screen/window coord conversion — and doesn't need
        // Accessibility or Input Monitoring permissions.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollWallpaperMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        wallpaperPollTimer = t

        // Local monitor: clicks delivered to our app still reach us even when
        // our window isn't key (e.g. the user just Cmd-Tabbed back).
        wallpaperLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged]
        ) { [weak self] event in
            self?.handleWallpaperClick(event)
            return event
        }

        // Global monitor: clicks delivered to other apps (e.g. the user
        // is working in a text editor and clicks on an exposed bit of
        // "wallpaper"). Only mouseDown — drags aren't useful here.
        wallpaperGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            self?.handleWallpaperClick(event)
        }
    }

    private func stopWallpaperInput() {
        wallpaperPollTimer?.invalidate()
        wallpaperPollTimer = nil
        if let m = wallpaperLocalMonitor { NSEvent.removeMonitor(m); wallpaperLocalMonitor = nil }
        if let m = wallpaperGlobalMonitor { NSEvent.removeMonitor(m); wallpaperGlobalMonitor = nil }
    }

    private func pollWallpaperMouse() {
        guard let pos = currentMouseNormalised() else { return }
        renderer.updateMouseNormalized(pos)
        noteInteraction()
    }

    private func handleWallpaperClick(_ event: NSEvent) {
        guard event.type == .leftMouseDown || event.type == .leftMouseDragged else { return }
        guard let pos = currentMouseNormalised() else { return }
        if event.type == .leftMouseDown {
            renderer.impulseClick(at: pos)
        } else {
            renderer.updateMouseNormalized(pos)
        }
        noteInteraction()
    }

    private func currentMouseNormalised() -> SIMD2<Float>? {
        guard let w = window, bounds.width > 0, bounds.height > 0 else { return nil }
        let screenLoc = NSEvent.mouseLocation          // screen coords, bottom-left origin
        let winLoc    = w.convertPoint(fromScreen: screenLoc)
        let viewLoc   = convert(winLoc, from: nil)
        return SIMD2<Float>(Float(viewLoc.x / bounds.width),
                            Float(viewLoc.y / bounds.height))
    }

    deinit {
        stopWallpaperInput()
        screensaverTimer?.invalidate()
    }
}
