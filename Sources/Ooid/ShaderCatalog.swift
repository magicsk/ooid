import Foundation
import simd

struct ShaderOption {
    let name: String
    let defaultValue: Float    // 0..1
    let units: String?         // optional suffix for the slider readout
}

// 3-stop colour palette (shadow / mid / hot). Any shader that wires up the
// `col0..2` uniforms can consume these. Currently only the flow field does.
struct ColorPreset {
    let name: String
    let shadow: SIMD4<Float>
    let mid:    SIMD4<Float>
    let hot:    SIMD4<Float>
}

struct ShaderEntry {
    let fragmentFunction: String
    let shortLabel: String
    let num: String
    let sub: String
    let title: String         // plain-text title
    let emWord: String        // word rendered as "em" (italicised) in the overlay
    let desc: String
    let params: [(String, String)]
    let options: [ShaderOption]   // 0..4 options; maps to uniform opt.xyzw
    // Multiplier on the view's quality level (px/pt, capped at native; the layer
    // bilinear-upscales the rest). Tuned so each shader stays under ~0.24 ms of
    // M1 Max GPU per frame on a 16" MBP at 120 fps — below that the GPU idles
    // between frames and reads ~0% busy, just above it jumps to 11–15%.
    // Re-tune with `swift run -c release Ooid --bench`.
    let renderScale: CGFloat

    init(fragmentFunction: String, shortLabel: String, num: String, sub: String,
         title: String, emWord: String, desc: String, params: [(String, String)],
         options: [ShaderOption] = [], renderScale: CGFloat = 1) {
        self.fragmentFunction = fragmentFunction
        self.shortLabel = shortLabel
        self.num = num
        self.sub = sub
        self.title = title
        self.emWord = emWord
        self.desc = desc
        self.params = params
        self.options = options
        self.renderScale = renderScale
    }
}

enum ShaderCatalog {
    static let entries: [ShaderEntry] = [
        ShaderEntry(
            fragmentFunction: "fs1_mercury",
            shortLabel: "Mercury",
            num: "SURFACE 01",
            sub: "Refractive metal surface",
            title: "Liquid mercury caustics",
            emWord: "caustics",
            desc: "A mirrored metal pool. The cursor becomes a gravity well, bending the surface and refracting caustics onto the depth below.",
            params: [("material", "Hg-alloy"), ("light", "HDRI · cold"), ("ior", "1.89")],
            renderScale: 0.68
        ),
        ShaderEntry(
            fragmentFunction: "fs2_aurora",
            shortLabel: "Aurora",
            num: "SURFACE 02",
            sub: "Raymarched volumetric gas",
            title: "Volumetric aurora smoke",
            emWord: "smoke",
            desc: "Charged particles drift through a magnetic field. Your cursor is a warm thermal — convection stirs the plume and pulls colour along the field lines.",
            params: [("material", "ionised gas"), ("light", "emissive"), ("density", "0.42")],
            renderScale: 0.2
        ),
        ShaderEntry(
            fragmentFunction: "fs3_soap",
            shortLabel: "Soap film",
            num: "SURFACE 03",
            sub: "Thin-film interference",
            title: "Iridescent soap film",
            emWord: "soap film",
            desc: "A nanometre-thin membrane stretched across the screen. The cursor pinches it — thickness shifts, and so does the wavelength of constructive interference.",
            params: [("material", "thin film"), ("light", "broadband"), ("thickness", "120–540nm")]
        ),
        ShaderEntry(
            fragmentFunction: "fs4_crystal",
            shortLabel: "Crystal",
            num: "SURFACE 04",
            sub: "Prismatic light splitting",
            title: "Diffraction crystal",
            emWord: "crystal",
            desc: "A rotating lattice of transparent crystals. The cursor is the sun — it splits into its spectrum as it refracts through each facet.",
            params: [("material", "quartz lattice"), ("light", "collimated"), ("dispersion", "0.14")],
            renderScale: 0.6
        ),
        ShaderEntry(
            fragmentFunction: "fs5_silk",
            shortLabel: "Plasma silk",
            num: "SURFACE 05",
            sub: "Anisotropic fibre scattering",
            title: "Plasma silk",
            emWord: "silk",
            desc: "Woven silk threads with anisotropic highlights, lit by a hovering point of plasma. Strands catch light perpendicular to their weave.",
            params: [("material", "spider silk"), ("light", "plasma arc"), ("fibres", "2400/mm")],
            renderScale: 0.96
        ),
        ShaderEntry(
            fragmentFunction: "fs6_foil",
            shortLabel: "Foil",
            num: "SURFACE 06",
            sub: "Surface-relief diffraction grating",
            title: "Holographic foil",
            emWord: "foil",
            desc: "An embossed holographic foil. Microscopic grooves split white light by angle — tilt your cursor and the entire rainbow spectrum slides across the surface.",
            params: [("material", "Mylar foil"), ("light", "halogen"), ("pitch", "1200 lines/mm")],
            renderScale: 0.8
        ),
        ShaderEntry(
            fragmentFunction: "fs7_ferro",
            shortLabel: "Ferrofluid",
            num: "SURFACE 07",
            sub: "Magnetic fluid instability",
            title: "Ferrofluid spikes",
            emWord: "spikes",
            desc: "A pool of magnetised nanoparticle oil. The cursor is a rare-earth magnet — the Rosensweig instability erupts into a crown of iron spikes that track it.",
            params: [("material", "Fe₃O₄ oil"), ("light", "raking"), ("flux", "0.8 T")],
            renderScale: 0.62
        ),
        ShaderEntry(
            fragmentFunction: "fs8_oil",
            shortLabel: "Oil",
            num: "SURFACE 08",
            sub: "Iridescent floating film",
            title: "Oil on water",
            emWord: "water",
            desc: "A thin film of petroleum floating on still water, lit from below. Your cursor disturbs the surface — ripples change the film thickness, cycling the spectrum.",
            params: [("material", "hydrocarbon"), ("light", "underlit"), ("film", "80–400nm")],
            renderScale: 0.75
        ),
        ShaderEntry(
            fragmentFunction: "fs9_bismuth",
            shortLabel: "Bismuth",
            num: "SURFACE 09",
            sub: "Stepped crystal oxidation",
            title: "Bismuth hopper",
            emWord: "hopper",
            desc: "A bismuth hopper crystal growing in real time. Its terraced staircases catch iridescent oxide colour. The cursor is heat — it dissolves and reforms structure.",
            params: [("material", "Bi₂O₃ skin"), ("light", "warm ambient"), ("steps", "8 tiers")],
            renderScale: 0.55
        ),
        ShaderEntry(
            fragmentFunction: "fs10_lens",
            shortLabel: "Lens",
            num: "SURFACE 10",
            sub: "Schwarzschild light bending",
            title: "Gravitational lens",
            emWord: "lens",
            desc: "A cursor-sized black hole warps the stars behind it. Light rays bend by GM/rc², forming a photon ring and an accretion disk of relativistic plasma.",
            params: [("material", "spacetime"), ("light", "starfield"), ("rs", "0.15")],
            renderScale: 0.85
        ),
        ShaderEntry(
            fragmentFunction: "fs11_drift",
            shortLabel: "Drift",
            num: "SURFACE 11",
            sub: "Flow-field colour drift",
            title: "Colour drift",
            emWord: "drift",
            desc: "Seven layers of pastel ribbons meander through a noise-warped flow field. Your cursor bends the current — the ribbons curl toward it before drifting past and recomposing.",
            params: [("material", "flow field"), ("light", "pastel emissive"), ("layers", "7")],
            renderScale: 0.4
        ),
        ShaderEntry(
            fragmentFunction: "fs12_flowfield",
            shortLabel: "Flow field",
            num: "SURFACE 12",
            sub: "Oriented copper stipple field",
            title: "Copper flow field",
            emWord: "flow",
            desc: "A dense grid of copper rods aligned to a slowly-evolving curl field. Vortex eyes open where the density mask dips to zero. Your cursor bends nearby streaks toward it and packs them tighter.",
            params: [("material", "copper stipple"), ("light", "additive"), ("density", "36/u²")],
            options: [
                ShaderOption(name: "Darkness",   defaultValue: 0.40, units: nil),
                ShaderOption(name: "Rod length", defaultValue: 1.00, units: nil),
                ShaderOption(name: "Swirl",      defaultValue: 1.00, units: nil),
                ShaderOption(name: "Wind speed", defaultValue: 0.70, units: nil),
            ],
            renderScale: 1.7    // instanced rods are cheap; thin rods want the pixels
        ),
        ShaderEntry(
            fragmentFunction: "fs13_ripple",
            shortLabel: "Ripple",
            num: "SURFACE 13",
            sub: "Shadowgraph wave interference",
            title: "Ripple tank interference",
            emWord: "interference",
            desc: "Three dippers beat on a shallow tank and their wavefronts cross into nodal lines. The cursor is a fourth source — sweep it to bend the fringes. Click to drop a stone.",
            params: [("medium", "water, 4 mm"), ("light", "overhead point"), ("λ", "22 mm")]
        ),
        ShaderEntry(
            fragmentFunction: "fs14_contour",
            shortLabel: "Contours",
            num: "SURFACE 14",
            sub: "Isoline terrain survey",
            title: "Topographic contours",
            emWord: "contours",
            desc: "A slowly eroding landscape surveyed in isolines, every fifth one an index contour, soundings below sea level. Your cursor is tectonic uplift — a summit rises and the lines bunch. Click for a meteor crater.",
            params: [("interval", "50 m"), ("index", "every 5th"), ("datum", "sea level")],
            renderScale: 1.2
        ),
        ShaderEntry(
            fragmentFunction: "fs15_marble",
            shortLabel: "Marbling",
            num: "SURFACE 15",
            sub: "Suminagashi floating ink",
            title: "Suminagashi marbling",
            emWord: "marbling",
            desc: "Drops of ink and clear water bloom on still water in bursts, each one shouldering every older ring aside. Your cursor is a fan across the surface; click to let a drop fall.",
            params: [("ink", "sumi · bengara"), ("medium", "still water"), ("drops", "90 live")],
            renderScale: 0.8
        ),
        ShaderEntry(
            fragmentFunction: "fs16_lava",
            shortLabel: "Lava",
            num: "SURFACE 16",
            sub: "Paraffin convection",
            title: "Lava lamp wax",
            emWord: "wax",
            desc: "Blobs of paraffin heat at the base, rise, cool and sink through a tinted solvent, merging and splitting as they pass. The cursor is a heating coil — wax swells toward it. Click to calve a bubble.",
            params: [("material", "paraffin"), ("light", "bulb, below"), ("blobs", "8")]
        ),
        ShaderEntry(
            fragmentFunction: "fs17_galaxy",
            shortLabel: "Galaxy",
            num: "SURFACE 17",
            sub: "Grand-design spiral",
            title: "Spiral galaxy",
            emWord: "galaxy",
            desc: "A two-armed density wave turning through a disk of old stars, dust lanes trailing each arm and pink nurseries flaring along them. Your cursor tilts the disk; click for a supernova.",
            params: [("type", "SAc"), ("arms", "m = 2"), ("pitch", "13°")]
        ),
        ShaderEntry(
            fragmentFunction: "fs18_halftone",
            shortLabel: "Halftone",
            num: "SURFACE 18",
            sub: "Three-screen dot modulation",
            title: "Halftone tide",
            emWord: "tide",
            desc: "Three rotated dot screens — red, green, blue — sample a rolling swell, each dot sized by the wave beneath it, mixing to white where they overlap. The cursor is a loupe; click to send a ripple through.",
            params: [("screens", "15° 45° 75°"), ("ruling", "24 lpi"), ("mix", "additive")],
            renderScale: 1.1
        ),
        ShaderEntry(
            fragmentFunction: "fs19_glass",
            shortLabel: "Glass",
            num: "SURFACE 19",
            sub: "Leaded Voronoi glazing",
            title: "Stained glass",
            emWord: "glass",
            desc: "Jewel-toned panes cut from a slowly drifting Voronoi diagram and leaded along every seam. Your cursor is the sun behind the window; click and a pulse of light runs pane to pane.",
            params: [("panes", "Voronoi"), ("came", "lead, 6 mm"), ("light", "transmitted")],
            renderScale: 0.8
        ),
        ShaderEntry(
            fragmentFunction: "fs20_fireflies",
            shortLabel: "Fireflies",
            num: "SURFACE 20",
            sub: "Synchronous bioluminescence",
            title: "Synchronous fireflies",
            emWord: "fireflies",
            desc: "Fireflies drift over a meadow at dusk, flashing in trains that slowly fall into step across the whole swarm. They gather toward your cursor; click and they all answer at once.",
            params: [("species", "P. carolinus"), ("swarm", "480"), ("flash", "5 × 0.4 s")]
        ),
        ShaderEntry(
            fragmentFunction: "fs21_phosphor",
            shortLabel: "Phosphor",
            num: "SURFACE 21",
            sub: "Persistence oscilloscope",
            title: "Phosphor Lissajous",
            emWord: "Lissajous",
            desc: "A three-axis Lissajous knot traced by an electron beam on long-persistence phosphor; where the beam slows it burns brightest. Cursor X sets the frequency ratio, Y the phase. Click to spike the beam.",
            params: [("phosphor", "P31"), ("beam", "1024 seg"), ("decay", "120 ms")]
        ),
        ShaderEntry(
            fragmentFunction: "fs22_turing",
            shortLabel: "Turing",
            num: "SURFACE 22",
            sub: "Gray–Scott reaction–diffusion",
            title: "Turing coral",
            emWord: "coral",
            desc: "Two chemicals feed, react and diffuse on a live grid, and spots, worms and coral grow out of nothing. Feed and kill rates drift, so the reef never settles. Your moving cursor drips catalyst; click to seed a ring.",
            params: [("model", "Gray–Scott"), ("feed", "0.055"), ("kill", "0.062")]
        ),
    ]

    // Returns the default opt.xyzw vector for a given shader index — used
    // as the "starting value" for sliders and when the user hasn't touched
    // anything yet.
    static func defaultOptionVector(for shaderIndex: Int) -> SIMD4<Float> {
        guard shaderIndex >= 0 && shaderIndex < entries.count else {
            return SIMD4<Float>(0, 0, 0, 0)
        }
        let opts = entries[shaderIndex].options
        return SIMD4<Float>(
            opts.count > 0 ? opts[0].defaultValue : 0,
            opts.count > 1 ? opts[1].defaultValue : 0,
            opts.count > 2 ? opts[2].defaultValue : 0,
            opts.count > 3 ? opts[3].defaultValue : 0
        )
    }

    // Colour presets — currently exposed for the flow-field shader. The
    // values are in NSColorWell-friendly 0..1 sRGB space; the shader boosts
    // them internally for HDR pop through the tonemap.
    static let flowFieldPresets: [ColorPreset] = [
        ColorPreset(name: "Copper",
                    shadow: SIMD4<Float>(0.35, 0.07, 0.015, 1),
                    mid:    SIMD4<Float>(1.00, 0.42, 0.10,  1),
                    hot:    SIMD4<Float>(1.00, 0.78, 0.25,  1)),
        ColorPreset(name: "Emerald",
                    shadow: SIMD4<Float>(0.04, 0.22, 0.10,  1),
                    mid:    SIMD4<Float>(0.15, 0.95, 0.45,  1),
                    hot:    SIMD4<Float>(0.75, 1.00, 0.85,  1)),
        ColorPreset(name: "Sapphire",
                    shadow: SIMD4<Float>(0.04, 0.08, 0.32,  1),
                    mid:    SIMD4<Float>(0.20, 0.50, 1.00,  1),
                    hot:    SIMD4<Float>(0.75, 0.92, 1.00,  1)),
        ColorPreset(name: "Amethyst",
                    shadow: SIMD4<Float>(0.22, 0.05, 0.30,  1),
                    mid:    SIMD4<Float>(0.70, 0.25, 1.00,  1),
                    hot:    SIMD4<Float>(1.00, 0.75, 1.00,  1)),
        ColorPreset(name: "Crimson",
                    shadow: SIMD4<Float>(0.35, 0.03, 0.08,  1),
                    mid:    SIMD4<Float>(1.00, 0.18, 0.22,  1),
                    hot:    SIMD4<Float>(1.00, 0.65, 0.45,  1)),
        ColorPreset(name: "Monochrome",
                    shadow: SIMD4<Float>(0.08, 0.08, 0.08,  1),
                    mid:    SIMD4<Float>(0.55, 0.55, 0.55,  1),
                    hot:    SIMD4<Float>(1.00, 1.00, 1.00,  1)),
    ]

    // Identity colour set so shaders that don't consume the palette see
    // something deterministic (all white, doesn't matter — they ignore it).
    static let identityColorSet: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        SIMD4<Float>(1, 1, 1, 1),
        SIMD4<Float>(1, 1, 1, 1),
        SIMD4<Float>(1, 1, 1, 1)
    )

    static func defaultColorSet(for shaderIndex: Int)
        -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    {
        // Index 11 = flow field.
        if shaderIndex == 11, let copper = flowFieldPresets.first {
            return (copper.shadow, copper.mid, copper.hot)
        }
        return identityColorSet
    }
}
