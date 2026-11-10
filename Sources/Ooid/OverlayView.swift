import AppKit

// AppKit overlay drawn above the Metal layer. Corresponds to the HTML chrome:
// top brand + meta readout, centred stage title, bottom nav + cursor hint,
// corner crosshairs. (Film grain is drawn in Shaders.metal.)
final class OverlayView: NSView {

    // MARK: - Palette
    static let fg       = NSColor(calibratedRed: 232/255, green: 230/255, blue: 223/255, alpha: 1.0)
    static let fgDim    = NSColor(calibratedRed: 232/255, green: 230/255, blue: 223/255, alpha: 0.55)
    static let fgFaint  = NSColor(calibratedRed: 232/255, green: 230/255, blue: 223/255, alpha: 0.22)
    static let chip     = NSColor(calibratedRed: 232/255, green: 230/255, blue: 223/255, alpha: 0.06)
    static let chipHi   = NSColor(calibratedRed: 232/255, green: 230/255, blue: 223/255, alpha: 0.12)
    static let stroke   = NSColor(calibratedRed: 232/255, green: 230/255, blue: 223/255, alpha: 0.14)

    // MARK: - Subviews
    private let brandMark   = NSTextField(labelWithString: "")
    private let brandSub    = NSTextField(labelWithString: "")
    private let brandDot    = DotView(frame: .zero)
    private let brandStack  = NSStackView()

    private let coordLabel  = LabelRow(title: "coord", value: "0.50, 0.50")
    private let intensityRow = IntensityRow()
    private let shaderLabel = LabelRow(title: "shader", value: "01/\(ShaderCatalog.entries.count)")

    private let stageNum    = NSTextField(labelWithString: "SURFACE 01")
    private let stageTitle  = NSTextField(labelWithString: "")
    private let stageDesc   = NSTextField(labelWithString: "")
    private let stageParams = NSStackView()

    private let nav         = FlowStackView()
    private let hintLabel   = NSTextField(labelWithString: "")
    private let wallpaperButton = NavButton()
    private let screensaverButton = NavButton()
    private let tuneButton      = NavButton()

    private let cornerSize: CGFloat = 10
    private let optionsPanel = OptionsPanel()

    // Callbacks
    var onSelect: ((Int) -> Void)?
    var onToggleWallpaper: (() -> Void)?
    var onToggleScreensaver: (() -> Void)?
    var onOptionChanged: ((Int, Float) -> Void)?   // (slot, value)
    var onMouseEffectsToggled: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onColorChanged: ((Int, SIMD4<Float>) -> Void)?
    var onColorPresetApplied: (((SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) -> Void)?

    private var isChromeHidden = false
    private var chromeViewsToHide: [NSView] = []
    // Remember whether the options panel was showing before chrome was
    // hidden, so we can put it back the way the user had it on exit.
    private var optionsPanelWasVisibleBeforeHide: Bool = false

    // Current shader for the options panel to read from.
    private var currentIndex: Int = 0

    override var isFlipped: Bool { true }   // top-left origin to match web layout more naturally

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false


        // Brand (top-left)
        brandDot.wantsLayer = true
        brandDot.translatesAutoresizingMaskIntoConstraints = false
        brandDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        brandDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        brandMark.stringValue = "OS/XR · WALLPAPER LAB"
        brandMark.font = Self.monoFont(size: 11, weight: .medium)
        brandMark.textColor = Self.fg
        brandMark.setAccessibilityIdentifier("brand-mark")
        applyTrackedStyle(brandMark, tracking: 0.18)

        brandSub.stringValue = "Interactive surface rendering"
        brandSub.font = Self.monoFont(size: 11, weight: .regular)
        brandSub.textColor = Self.fgFaint
        applyTrackedStyle(brandSub, tracking: 0.14)

        let brandRow = NSStackView()
        brandRow.orientation = .horizontal
        brandRow.spacing = 10
        brandRow.alignment = .centerY
        brandRow.addArrangedSubview(brandDot)
        brandRow.addArrangedSubview(brandMark)

        brandStack.orientation = .vertical
        brandStack.alignment = .leading
        brandStack.spacing = 4
        brandStack.addArrangedSubview(brandRow)
        brandStack.addArrangedSubview(brandSub)
        brandStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brandStack)

        // Meta (top-right)
        let metaStack = NSStackView(views: [coordLabel, intensityRow, shaderLabel])
        metaStack.orientation = .vertical
        metaStack.alignment = .trailing
        metaStack.spacing = 6
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaStack)

        // Stage (centre-left)
        stageNum.font = Self.monoFont(size: 11, weight: .regular)
        stageNum.textColor = Self.fgFaint
        applyTrackedStyle(stageNum, tracking: 0.2)

        stageTitle.font = Self.interFont(size: 72, weight: .light)
        stageTitle.textColor = Self.fg
        stageTitle.maximumNumberOfLines = 3
        stageTitle.cell?.wraps = true
        stageTitle.cell?.isScrollable = false
        stageTitle.preferredMaxLayoutWidth = 620
        applyTitleStyle(stageTitle)

        stageDesc.font = NSFont.systemFont(ofSize: 13)
        stageDesc.textColor = Self.fgDim
        stageDesc.maximumNumberOfLines = 6
        stageDesc.cell?.wraps = true
        stageDesc.cell?.isScrollable = false
        stageDesc.preferredMaxLayoutWidth = 440

        stageParams.orientation = .horizontal
        stageParams.spacing = 20

        let stageStack = NSStackView(views: [stageNum, stageTitle, stageDesc, stageParams])
        stageStack.orientation = .vertical
        stageStack.alignment = .leading
        stageStack.spacing = 14
        stageStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stageStack)

        // Nav (bottom-left)
        nav.hSpacing = 6
        nav.vSpacing = 6
        nav.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nav)

        // Buttons + hint (bottom-right).
        //   · Wallpaper mode drops the window to desktop level (behind apps).
        //   · Screensaver mode raises it to screensaver level (above everything);
        //     auto-cycles shaders, and exits on click or key press.
        wallpaperButton.setLabel(index: nil, text: "Wallpaper")
        wallpaperButton.target = self
        wallpaperButton.action = #selector(wallpaperClicked(_:))
        screensaverButton.setLabel(index: nil, text: "Screensaver")
        screensaverButton.target = self
        screensaverButton.action = #selector(screensaverClicked(_:))
        tuneButton.setLabel(index: nil, text: "Tune")
        tuneButton.target = self
        tuneButton.action = #selector(tuneClicked(_:))

        hintLabel.stringValue = "◯   MOVE · CLICK TO PERTURB"
        hintLabel.font = Self.monoFont(size: 11, weight: .regular)
        hintLabel.textColor = Self.fgFaint
        applyTrackedStyle(hintLabel, tracking: 0.14)

        let bottomRightStack = NSStackView(views: [tuneButton, wallpaperButton, screensaverButton, hintLabel])
        bottomRightStack.orientation = .horizontal
        bottomRightStack.spacing = 10
        bottomRightStack.alignment = .centerY
        bottomRightStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomRightStack)

        optionsPanel.translatesAutoresizingMaskIntoConstraints = false
        optionsPanel.isHidden = true
        optionsPanel.onOptionChanged = { [weak self] slot, value in
            self?.onOptionChanged?(slot, value)
        }
        optionsPanel.onMouseEffectsToggled = { [weak self] enabled in
            self?.onMouseEffectsToggled?(enabled)
        }
        optionsPanel.onOpenSettings = { [weak self] in
            self?.onOpenSettings?()
        }
        optionsPanel.onColorChanged = { [weak self] slot, value in
            self?.onColorChanged?(slot, value)
        }
        optionsPanel.onColorPresetApplied = { [weak self] cs in
            self?.onColorPresetApplied?(cs)
        }
        addSubview(optionsPanel)

        // Corner crosshairs
        for corner in [CornerType.tl, .tr, .bl, .br] {
            let v = CornerCrossView(frame: .zero, corner: corner)
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            brandStack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            brandStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),

            metaStack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            metaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            stageStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stageStack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),

            nav.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            nav.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            // Cap nav's width so it can't intrude under the bottom-right
            // button stack — otherwise nav & buttons draw over each other
            // on narrower windows.
            nav.trailingAnchor.constraint(lessThanOrEqualTo: bottomRightStack.leadingAnchor, constant: -14),

            bottomRightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            bottomRightStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),

            optionsPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            optionsPanel.bottomAnchor.constraint(equalTo: bottomRightStack.topAnchor, constant: -14),
            optionsPanel.widthAnchor.constraint(equalToConstant: 320),
        ])

        // Chrome = everything except the exit hint.
        chromeViewsToHide = [brandStack, metaStack, stageStack, nav, bottomRightStack]

        populateNav()
        buildCornerConstraints()

        // Let the brand dot glow
        brandDot.fillColor = Self.fg

        render(index: 0, coord: SIMD2<Float>(0.5, 0.5), intensity: 0.3)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // On narrow windows the hint text collides with the right-hand
        // button row; hide it below a threshold so the buttons always fit.
        let hideHint = bounds.width < 1040
        if hintLabel.isHidden != hideHint { hintLabel.isHidden = hideHint }
    }

    // MARK: - Nav
    private var navButtons: [NSButton] = []
    private func populateNav() {
        navButtons.removeAll()
        nav.subviews.forEach { $0.removeFromSuperview() }
        for (i, entry) in ShaderCatalog.entries.enumerated() {
            let b = NavButton()
            b.setLabel(index: i + 1, text: entry.shortLabel)
            b.tag = i
            b.target = self
            b.action = #selector(navClicked(_:))
            nav.addSubview(b)
            navButtons.append(b)
        }
        nav.needsLayout = true
    }
    @objc private func navClicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
    @objc private func wallpaperClicked(_ sender: NSButton) {
        onToggleWallpaper?()
    }
    @objc private func screensaverClicked(_ sender: NSButton) {
        onToggleScreensaver?()
    }
    @objc private func tuneClicked(_ sender: NSButton) {
        optionsPanel.isHidden = !optionsPanel.isHidden
    }

    func applyOptionValues(_ values: SIMD4<Float>, mouseEffectsEnabled: Bool) {
        optionsPanel.syncFromValues(values, mouseEffectsEnabled: mouseEffectsEnabled)
    }
    func applyColorSet(_ cs: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        optionsPanel.syncColors(cs)
    }

    // MARK: - Chrome visibility (shared by wallpaper & screensaver modes)
    func setChromeHidden(_ on: Bool) {
        // Snapshot / restore the options-panel visibility so that opening
        // wallpaper or screensaver mode always hides it, and exiting those
        // modes puts it back to whatever the user had before.
        if on && !isChromeHidden {
            optionsPanelWasVisibleBeforeHide = !optionsPanel.isHidden
        }
        isChromeHidden = on
        for v in chromeViewsToHide { v.isHidden = on }
        for v in subviews where v is CornerCrossView { v.isHidden = on }
        optionsPanel.isHidden = on ? true : !optionsPanelWasVisibleBeforeHide
    }

    // MARK: - External updates
    private var lastRenderedIndex: Int = -1

    // Full chrome refresh — only rebuild pills / title when the shader actually
    // changes. At 10 Hz live updates this saves a measurable amount of CPU
    // autolayout work.
    func render(index: Int, coord: SIMD2<Float>, intensity: Float) {
        if index != lastRenderedIndex {
            applyShaderChrome(index: index)
            lastRenderedIndex = index
        }
        applyLiveReadout(index: index, coord: coord, intensity: intensity)
    }

    private func applyShaderChrome(index: Int) {
        currentIndex = index
        let entry = ShaderCatalog.entries[index]
        stageNum.stringValue = entry.num
        applyTrackedStyle(stageNum, tracking: 0.2)
        applyTitle(title: entry.title, em: entry.emWord)
        stageDesc.stringValue = entry.desc

        stageParams.arrangedSubviews.forEach { stageParams.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (k, v) in entry.params {
            stageParams.addArrangedSubview(Self.paramPill(key: k, val: v))
        }

        for (i, b) in navButtons.enumerated() {
            (b as? NavButton)?.isSelected = (i == index)
        }

        optionsPanel.configure(for: entry)
        // The panel always has the global Mouse/Screensaver section, so the
        // Tune button stays visible even for shaders without per-shader opts.
    }

    private func applyLiveReadout(index: Int, coord: SIMD2<Float>, intensity: Float) {
        coordLabel.value = String(format: "%.2f, %.2f", coord.x, coord.y)
        intensityRow.value = intensity
        let idxStr = index + 1 < 10 ? "0\(index + 1)" : "\(index + 1)"
        shaderLabel.value = "\(idxStr)/\(ShaderCatalog.entries.count)"
    }

    private func applyTitle(title: String, em: String) {
        let attr = NSMutableAttributedString()
        let main = NSAttributedString(string: title, attributes: Self.titleAttrs(italic: false))
        // Simple replacement: find em word (case-insensitive), italicise.
        if let range = title.range(of: em, options: .caseInsensitive) {
            let before = String(title[..<range.lowerBound])
            let middle = String(title[range])
            let after  = String(title[range.upperBound...])
            attr.append(NSAttributedString(string: before, attributes: Self.titleAttrs(italic: false)))
            attr.append(NSAttributedString(string: middle, attributes: Self.titleAttrs(italic: true)))
            attr.append(NSAttributedString(string: after,  attributes: Self.titleAttrs(italic: false)))
        } else {
            attr.append(main)
        }
        stageTitle.attributedStringValue = attr
    }

    private static func titleAttrs(italic: Bool) -> [NSAttributedString.Key: Any] {
        let pStyle = NSMutableParagraphStyle()
        pStyle.maximumLineHeight = 0.98 * 72
        pStyle.lineHeightMultiple = 0.98
        pStyle.alignment = .natural
        let font: NSFont
        if italic {
            let base = interFont(size: 72, weight: .light)
            let italicDesc = base.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: italicDesc, size: 72) ?? base
        } else {
            font = interFont(size: 72, weight: .light)
        }
        return [
            .font: font,
            .foregroundColor: italic ? fgDim : fg,
            .kern: -0.035 * 72,
            .paragraphStyle: pStyle,
        ]
    }

    // MARK: - Fonts
    static func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
    static func interFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // Prefer Inter Tight if installed; fall back to system font otherwise.
        if let font = NSFont(name: "Inter Tight", size: size) {
            return font.withWeight(weight)
        }
        if let font = NSFont(name: "Inter", size: size) {
            return font.withWeight(weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func applyTrackedStyle(_ field: NSTextField, tracking: CGFloat) {
        guard !field.stringValue.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: field.font ?? Self.monoFont(size: 11, weight: .regular),
            .foregroundColor: field.textColor ?? Self.fgDim,
            .kern: tracking * (field.font?.pointSize ?? 11),
        ]
        field.attributedStringValue = NSAttributedString(string: field.stringValue.uppercased(), attributes: attrs)
    }
    private func applyTitleStyle(_ field: NSTextField) {
        field.cell?.wraps = true
    }

    private static func paramPill(key: String, val: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.font = monoFont(size: 11, weight: .regular)
        let kAttr: [NSAttributedString.Key: Any] = [
            .font: monoFont(size: 11, weight: .regular),
            .foregroundColor: fgFaint,
            .kern: 0.1 * 11,
        ]
        let vAttr: [NSAttributedString.Key: Any] = [
            .font: monoFont(size: 11, weight: .medium),
            .foregroundColor: fgDim,
            .kern: 0.05 * 11,
        ]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: key.uppercased() + "  ", attributes: kAttr))
        s.append(NSAttributedString(string: val, attributes: vAttr))
        label.attributedStringValue = s
        return label
    }

    // MARK: - Corner crosshairs
    private func buildCornerConstraints() {
        for sub in subviews {
            guard let cross = sub as? CornerCrossView else { continue }
            cross.widthAnchor.constraint(equalToConstant: cornerSize).isActive = true
            cross.heightAnchor.constraint(equalToConstant: cornerSize).isActive = true
            switch cross.corner {
            case .tl:
                cross.topAnchor.constraint(equalTo: topAnchor, constant: 20).isActive = true
                cross.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20).isActive = true
            case .tr:
                cross.topAnchor.constraint(equalTo: topAnchor, constant: 20).isActive = true
                cross.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20).isActive = true
            case .bl:
                cross.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20).isActive = true
                cross.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20).isActive = true
            case .br:
                cross.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20).isActive = true
                cross.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20).isActive = true
            }
        }
    }

    // Overlay mustn't swallow clicks intended for the Metal view (except on our
    // own controls). Custom hit test lets them fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        return hit
    }
}

// MARK: - Support views

private final class DotView: NSView {
    var fillColor: NSColor = .white { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = bounds.width * 0.5
        layer?.backgroundColor = fillColor.cgColor
        layer?.shadowColor = fillColor.cgColor
        layer?.shadowRadius = 10
        layer?.shadowOpacity = 0.8
        layer?.shadowOffset = .zero
        layer?.masksToBounds = false
    }
}

private final class LabelRow: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")

    var value: String {
        get { valueField.stringValue }
        set {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: OverlayView.monoFont(size: 10.5, weight: .medium),
                .foregroundColor: OverlayView.fg,
                .kern: 0.12 * 10.5,
            ]
            valueField.attributedStringValue = NSAttributedString(string: newValue.uppercased(), attributes: attrs)
        }
    }

    init(title: String, value: String) {
        super.init(frame: .zero)
        let tAttrs: [NSAttributedString.Key: Any] = [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.12 * 10.5,
        ]
        titleField.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: tAttrs)
        let stack = NSStackView(views: [titleField, valueField])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.value = value
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class IntensityRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let bar = IntensityBar(frame: .zero)

    var value: Float {
        get { bar.value }
        set { bar.value = newValue }
    }
    init() {
        super.init(frame: .zero)
        let tAttrs: [NSAttributedString.Key: Any] = [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.12 * 10.5,
        ]
        title.attributedStringValue = NSAttributedString(string: "INTENSITY", attributes: tAttrs)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 62).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let stack = NSStackView(views: [title, bar])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class IntensityBar: NSView {
    var value: Float = 0.3 { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        OverlayView.stroke.setFill()
        bounds.fill()
        let w = bounds.width * CGFloat(max(0.1, min(1, 0.1 + value * 0.9)))
        let fillRect = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        OverlayView.fg.setFill()
        fillRect.fill()
    }
}

private final class CornerCrossView: NSView {
    let corner: OverlayView.CornerType
    init(frame: NSRect, corner: OverlayView.CornerType) {
        self.corner = corner
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        OverlayView.fgFaint.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        switch corner {
        case .tl:
            path.move(to: NSPoint(x: 0, y: bounds.height))
            path.line(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: bounds.width, y: 0))
        case .tr:
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: bounds.width, y: 0))
            path.line(to: NSPoint(x: bounds.width, y: bounds.height))
        case .bl:
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: bounds.height))
            path.line(to: NSPoint(x: bounds.width, y: bounds.height))
        case .br:
            path.move(to: NSPoint(x: bounds.width, y: 0))
            path.line(to: NSPoint(x: bounds.width, y: bounds.height))
            path.line(to: NSPoint(x: 0, y: bounds.height))
        }
        path.stroke()
    }
}

// Expose the corner enum to the nested view that needs it.
extension OverlayView {
    enum CornerType { case tl, tr, bl, br }
}

// Nav button with a subtle capsule background and an index prefix.
final class NavButton: NSButton {
    private let idxField   = NSTextField(labelWithString: "")
    private let labelField = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    var isSelected: Bool = false { didSet { needsDisplay = true; updateTextColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        setButtonType(.momentaryChange)

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(idxField)
        stack.addArrangedSubview(labelField)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateLayerAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setLabel(index: Int?, text: String) {
        if let index = index {
            let n = index < 10 ? "0\(index)" : "\(index)"
            idxField.attributedStringValue = NSAttributedString(string: n, attributes: [
                .font: OverlayView.monoFont(size: 9.5, weight: .regular),
                .foregroundColor: OverlayView.fgFaint,
                .kern: 0.14 * 9.5,
            ])
            idxField.isHidden = false
        } else {
            idxField.stringValue = ""
            idxField.isHidden = true
        }
        labelField.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.14 * 10.5,
        ])
    }

    private func updateTextColors() {
        let col = isSelected ? OverlayView.fg : OverlayView.fgDim
        let idxCol = isSelected ? OverlayView.fgDim : OverlayView.fgFaint
        if let s = labelField.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
            s.addAttribute(.foregroundColor, value: col, range: NSRange(0..<s.length))
            labelField.attributedStringValue = s
        }
        if let s = idxField.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
            s.addAttribute(.foregroundColor, value: idxCol, range: NSRange(0..<s.length))
            idxField.attributedStringValue = s
        }
        updateLayerAppearance()
    }

    private func updateLayerAppearance() {
        layer?.backgroundColor = (isSelected ? OverlayView.chipHi : OverlayView.chip).cgColor
        layer?.borderColor = (isSelected ? OverlayView.fgDim : OverlayView.stroke).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = OverlayView.chipHi.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = (isSelected ? OverlayView.chipHi : OverlayView.chip).cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let existing = trackingAreas.first { removeTrackingArea(existing) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
    }
}

// Minimal horizontal flow stack: lays subviews left-to-right and wraps to
// a new row when they run out of horizontal space. The last row sits at
// the bottom (y = 0, non-flipped coords) and subsequent rows stack above
// it, so when anchored bottom-left the view grows upward as items wrap.
final class FlowStackView: NSView {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    private var heightConstraint: NSLayoutConstraint?

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, !subviews.isEmpty else {
            updateHeight(0)
            return
        }

        // Group into rows.
        var rows: [[NSView]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for v in subviews {
            let sz = v.fittingSize
            let lastW = rowWidths.last ?? 0
            if lastW > 0 && lastW + sz.width > width {
                rows.append([])
                rowWidths.append(0)
            }
            rows[rows.count - 1].append(v)
            rowWidths[rowWidths.count - 1] += sz.width + hSpacing
        }
        let rowHeights = rows.map { row in row.map { $0.fittingSize.height }.max() ?? 0 }
        let totalH = rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * vSpacing

        // Lay out last row at y=0 (bottom) and build upward. First items of
        // the nav end up at the top of the stack which matches natural
        // reading order (1…5 on top, 6…N below).
        var yCursor: CGFloat = 0
        for (rowIdx, row) in rows.enumerated().reversed() {
            let rowH = rowHeights[rowIdx]
            var x: CGFloat = 0
            for v in row {
                let sz = v.fittingSize
                v.frame = NSRect(x: x, y: yCursor, width: sz.width, height: sz.height)
                x += sz.width + hSpacing
            }
            yCursor += rowH + vSpacing
        }
        updateHeight(totalH)
    }

    private func updateHeight(_ h: CGFloat) {
        if heightConstraint == nil {
            heightConstraint = heightAnchor.constraint(equalToConstant: h)
            heightConstraint?.priority = .defaultHigh
            heightConstraint?.isActive = true
        } else if heightConstraint!.constant != h {
            heightConstraint!.constant = h
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        needsLayout = true
    }
    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        needsLayout = true
    }
}

// Apply a target weight to an existing NSFont.
private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let traits = [NSFontDescriptor.TraitKey.weight: weight]
        let desc = fontDescriptor.addingAttributes([.traits: traits])
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }
}

// Options panel — floating glass card with sliders for the active shader's
// options and a "mouse effects" toggle.
final class OptionsPanel: NSView {

    var onOptionChanged: ((Int, Float) -> Void)?
    var onMouseEffectsToggled: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onColorChanged: ((Int, SIMD4<Float>) -> Void)?
    var onColorPresetApplied: (((SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let sliderStack = NSStackView()
    private let mouseToggle = NSButton(checkboxWithTitle: "MOUSE EFFECTS", target: nil, action: nil)
    private let settingsLinkButton = NSButton(title: "⚙  SETTINGS…", target: nil, action: nil)

    // Colour section (only shown when the current shader has a palette).
    private let colorSection = NSStackView()
    private let colorTitle = NSTextField(labelWithString: "")
    private let presetPopup = NSPopUpButton(title: "", target: nil, action: nil)
    private let shadowWell = NSColorWell(frame: .zero)
    private let midWell    = NSColorWell(frame: .zero)
    private let hotWell    = NSColorWell(frame: .zero)
    private var colorPresets: [ColorPreset] = []

    private var sliders: [(slot: Int, slider: NSSlider, label: NSTextField)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.82).cgColor
        layer?.borderColor = OverlayView.stroke.cgColor
        layer?.borderWidth = 1

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: OverlayView.monoFont(size: 11, weight: .medium),
            .foregroundColor: OverlayView.fg,
            .kern: 0.18 * 11,
        ]
        titleLabel.attributedStringValue = NSAttributedString(string: "OPTIONS", attributes: titleAttrs)

        sliderStack.orientation = .vertical
        sliderStack.alignment = .leading
        sliderStack.spacing = 10
        sliderStack.distribution = .fill

        mouseToggle.target = self
        mouseToggle.action = #selector(mouseToggleChanged(_:))
        mouseToggle.state = .on
        mouseToggle.attributedTitle = NSAttributedString(string: "MOUSE EFFECTS", attributes: [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.14 * 10.5,
        ])

        settingsLinkButton.bezelStyle = .inline
        settingsLinkButton.isBordered = false
        settingsLinkButton.target = self
        settingsLinkButton.action = #selector(settingsLinkClicked(_:))
        settingsLinkButton.attributedTitle = NSAttributedString(string: "⚙  SCREENSAVER & MENU BAR…", attributes: [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.14 * 10.5,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])

        // ---- Colour section ----
        colorTitle.attributedStringValue = NSAttributedString(string: "COLOUR", attributes: [
            .font: OverlayView.monoFont(size: 11, weight: .medium),
            .foregroundColor: OverlayView.fg,
            .kern: 0.18 * 11,
        ])
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        presetPopup.bezelStyle = .rounded
        presetPopup.translatesAutoresizingMaskIntoConstraints = false
        presetPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let presetLabel = NSTextField(labelWithString: "PRESET")
        presetLabel.attributedStringValue = NSAttributedString(string: "PRESET", attributes: [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.14 * 10.5,
        ])
        let presetRow = NSStackView(views: [presetLabel, presetPopup])
        presetRow.orientation = .vertical
        presetRow.alignment = .leading
        presetRow.spacing = 4

        for (i, well) in [shadowWell, midWell, hotWell].enumerated() {
            well.target = self
            well.action = #selector(colorWellChanged(_:))
            well.tag = i
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 46).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let shadowLabel = colorWellLabel("SHADOW")
        let midLabel    = colorWellLabel("MID")
        let hotLabel    = colorWellLabel("HOT")
        let shadowCol = NSStackView(views: [shadowLabel, shadowWell])
        let midCol    = NSStackView(views: [midLabel, midWell])
        let hotCol    = NSStackView(views: [hotLabel, hotWell])
        for c in [shadowCol, midCol, hotCol] {
            c.orientation = .vertical
            c.alignment = .leading
            c.spacing = 4
        }
        let wellsRow = NSStackView(views: [shadowCol, midCol, hotCol])
        wellsRow.orientation = .horizontal
        wellsRow.spacing = 22
        wellsRow.alignment = .top

        colorSection.orientation = .vertical
        colorSection.alignment = .leading
        colorSection.spacing = 10
        colorSection.addArrangedSubview(colorTitle)
        colorSection.addArrangedSubview(presetRow)
        colorSection.addArrangedSubview(wellsRow)

        let container = NSStackView(views: [titleLabel, sliderStack, colorSection, mouseToggle, settingsLinkButton])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(for entry: ShaderEntry) {
        // Rebuild slider rows for the entry's options.
        sliderStack.arrangedSubviews.forEach { sliderStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        sliders.removeAll(keepingCapacity: true)

        for (slot, opt) in entry.options.enumerated() {
            let row = makeSliderRow(slot: slot, opt: opt)
            sliderStack.addArrangedSubview(row.view)
            sliders.append((slot, row.slider, row.valueLabel))
        }

        // Palette presets — only the flow field surfaces this today. Future
        // shaders that want colour can add their own preset lists.
        let presets = entry.fragmentFunction == "fs12_flowfield"
            ? ShaderCatalog.flowFieldPresets
            : []
        colorPresets = presets
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: (presets.map { $0.name } + ["Custom"]))
        colorSection.isHidden = presets.isEmpty
    }

    // Sync the colour wells with the shader's current palette. Called by
    // AppDelegate whenever the active shader changes.
    func syncColors(_ cs: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        shadowWell.color = colorFromSIMD(cs.0)
        midWell.color    = colorFromSIMD(cs.1)
        hotWell.color    = colorFromSIMD(cs.2)
        // If the current colours match a preset, highlight it.
        if let i = colorPresets.firstIndex(where: {
            simdMatches($0.shadow, cs.0) && simdMatches($0.mid, cs.1) && simdMatches($0.hot, cs.2)
        }) {
            presetPopup.selectItem(at: i)
        } else {
            // "Custom" is the trailing entry.
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
        }
    }

    private func simdMatches(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        return abs(a.x - b.x) < 0.005 && abs(a.y - b.y) < 0.005 && abs(a.z - b.z) < 0.005
    }
    private func colorFromSIMD(_ c: SIMD4<Float>) -> NSColor {
        return NSColor(srgbRed: CGFloat(max(0, min(1, c.x))),
                       green: CGFloat(max(0, min(1, c.y))),
                       blue:  CGFloat(max(0, min(1, c.z))),
                       alpha: 1.0)
    }
    private func simdFromColor(_ c: NSColor) -> SIMD4<Float> {
        let s = c.usingColorSpace(.sRGB) ?? c
        return SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent),
                            Float(s.blueComponent), 1.0)
    }

    private func colorWellLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: OverlayView.monoFont(size: 9.5, weight: .regular),
            .foregroundColor: OverlayView.fgFaint,
            .kern: 0.14 * 9.5,
        ])
        return label
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0 && i < colorPresets.count else { return } // "Custom" = no-op
        let p = colorPresets[i]
        shadowWell.color = colorFromSIMD(p.shadow)
        midWell.color    = colorFromSIMD(p.mid)
        hotWell.color    = colorFromSIMD(p.hot)
        onColorPresetApplied?((p.shadow, p.mid, p.hot))
    }
    @objc private func colorWellChanged(_ sender: NSColorWell) {
        let v = simdFromColor(sender.color)
        onColorChanged?(sender.tag, v)
        // Selecting a custom colour drops us into "Custom" in the popup.
        presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
    }

    func syncFromValues(_ values: SIMD4<Float>, mouseEffectsEnabled: Bool) {
        let arr = [values.x, values.y, values.z, values.w]
        for (slot, slider, valueLabel) in sliders where slot < arr.count {
            let v = arr[slot]
            slider.doubleValue = Double(v)
            valueLabel.stringValue = String(format: "%.2f", v)
        }
        mouseToggle.state = mouseEffectsEnabled ? .on : .off
    }

    private func makeSliderRow(slot: Int, opt: ShaderOption)
        -> (view: NSView, slider: NSSlider, valueLabel: NSTextField)
    {
        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.attributedStringValue = NSAttributedString(string: opt.name.uppercased(), attributes: [
            .font: OverlayView.monoFont(size: 10.5, weight: .regular),
            .foregroundColor: OverlayView.fgDim,
            .kern: 0.14 * 10.5,
        ])

        let valueLabel = NSTextField(labelWithString: String(format: "%.2f", opt.defaultValue))
        valueLabel.font = OverlayView.monoFont(size: 10.5, weight: .medium)
        valueLabel.textColor = OverlayView.fg
        valueLabel.alignment = .right

        let header = NSStackView(views: [nameLabel, valueLabel])
        header.orientation = .horizontal
        header.distribution = .equalSpacing
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let slider = NSSlider(value: Double(opt.defaultValue), minValue: 0, maxValue: 1,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.tag = slot
        slider.isContinuous = true
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let row = NSStackView(views: [header, slider])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4

        return (row, slider, valueLabel)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let slot = sender.tag
        let value = Float(sender.doubleValue)
        if let i = sliders.firstIndex(where: { $0.slot == slot }) {
            sliders[i].label.stringValue = String(format: "%.2f", value)
        }
        onOptionChanged?(slot, value)
    }
    @objc private func mouseToggleChanged(_ sender: NSButton) {
        onMouseEffectsToggled?(sender.state == .on)
    }
    @objc private func settingsLinkClicked(_ sender: NSButton) {
        onOpenSettings?()
    }
}
