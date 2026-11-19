import Foundation
import simd

struct ShaderOption {
    let name: String
    let defaultValue: Float    // 0..1
    let units: String?         // optional suffix for the slider readout
}

// 3-stop colour palette, fed to the `col0..2` uniforms. What each stop means
// is up to the shader; its entry names them in `colorLabels`.
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
    // Non-empty = the options panel shows a colour section; the first preset is
    // the default palette. `colorLabels` names the three wells.
    let colorPresets: [ColorPreset]
    let colorLabels: [String]

    init(fragmentFunction: String, shortLabel: String, num: String, sub: String,
         title: String, emWord: String, desc: String, params: [(String, String)],
         options: [ShaderOption] = [], renderScale: CGFloat = 1,
         colorPresets: [ColorPreset] = [], colorLabels: [String] = ["SHADOW", "MID", "HOT"]) {
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
        self.colorPresets = colorPresets
        self.colorLabels = colorLabels
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
            renderScale: 1.7,   // instanced rods are cheap; thin rods want the pixels
            colorPresets: flowFieldPresets
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
            params: [("material", "paraffin"), ("light", "bulb, below"), ("blobs", "4–14")],
            options: [
                ShaderOption(name: "Flow",      defaultValue: 0.40, units: nil),
                ShaderOption(name: "Wax",       defaultValue: 0.50, units: nil),
                ShaderOption(name: "Blob size", defaultValue: 0.45, units: nil),
                ShaderOption(name: "Glow",      defaultValue: 0.50, units: nil),
            ],
            renderScale: 0.5,   // smooth field, analytic edge AA: upscales cleanly
            colorPresets: lavaPresets,
            colorLabels: ["SOLVENT", "WAX", "GLOW"]
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
        ShaderEntry(
            fragmentFunction: "fs23_rain",
            shortLabel: "Rain",
            num: "SURFACE 23",
            sub: "Refracting droplets on misted glass",
            title: "Rain on glass",
            emWord: "Rain",
            desc: "Drops cling to a misted pane, creep, then let go and run, each one a tiny lens holding the street lights upside down. Your cursor is a warm palm that clears the mist around it; click to land a fresh drop.",
            params: [("pane", "float glass, 4 mm"), ("outside", "sodium · f/1.4"), ("rain", "0.6 mm/h")],
            options: [
                ShaderOption(name: "Rain",      defaultValue: 0.50, units: nil),
                ShaderOption(name: "Drop size", defaultValue: 0.50, units: nil),
                ShaderOption(name: "Mist",      defaultValue: 0.50, units: nil),
                ShaderOption(name: "Lights",    defaultValue: 0.50, units: nil),
            ],
            renderScale: 0.5,   // defocused lights and pixel-relative drop edges: upscales cleanly
            colorPresets: [
                ColorPreset(name: "Sodium",
                            shadow: SIMD4<Float>(0.24, 0.46, 1.00, 1),
                            mid:    SIMD4<Float>(1.00, 0.56, 0.20, 1),
                            hot:    SIMD4<Float>(1.00, 0.17, 0.13, 1)),
                ColorPreset(name: "Neon",
                            shadow: SIMD4<Float>(0.46, 0.24, 1.00, 1),
                            mid:    SIMD4<Float>(1.00, 0.24, 0.66, 1),
                            hot:    SIMD4<Float>(0.10, 0.84, 1.00, 1)),
                ColorPreset(name: "Harbour",
                            shadow: SIMD4<Float>(0.08, 0.52, 0.60, 1),
                            mid:    SIMD4<Float>(1.00, 0.84, 0.56, 1),
                            hot:    SIMD4<Float>(0.16, 0.92, 0.56, 1)),
                ColorPreset(name: "Ember",
                            shadow: SIMD4<Float>(0.56, 0.22, 0.34, 1),
                            mid:    SIMD4<Float>(1.00, 0.42, 0.12, 1),
                            hot:    SIMD4<Float>(1.00, 0.76, 0.30, 1)),
                ColorPreset(name: "Moonlight",
                            shadow: SIMD4<Float>(0.34, 0.44, 0.62, 1),
                            mid:    SIMD4<Float>(0.80, 0.88, 1.00, 1),
                            hot:    SIMD4<Float>(0.44, 0.60, 1.00, 1)),
                ColorPreset(name: "Mono",
                            shadow: SIMD4<Float>(0.40, 0.40, 0.42, 1),
                            mid:    SIMD4<Float>(0.92, 0.90, 0.86, 1),
                            hot:    SIMD4<Float>(0.60, 0.60, 0.60, 1)),
            ],
            colorLabels: ["DUSK", "LAMPS", "ACCENT"]
        ),
        ShaderEntry(
            fragmentFunction: "fs24_jelly",
            shortLabel: "Jellyfish",
            num: "SURFACE 24",
            sub: "Deep-water bioluminescence",
            title: "Bioluminescent jellyfish",
            emWord: "jellyfish",
            desc: "A small bloom of jellies pulses through dark water, bells squeezing and tentacles trailing, marine snow sinking past. Your cursor is a gentle current that eases them aside; click and a flash ripples from jelly to jelly.",
            params: [("species", "A. victoria"), ("depth", "−180 m"), ("bloom", "1–8")],
            options: [
                ShaderOption(name: "Bloom", defaultValue: 0.7143, units: nil),
                ShaderOption(name: "Tempo", defaultValue: 0.50, units: nil),
                ShaderOption(name: "Glow",  defaultValue: 0.50, units: nil),
                ShaderOption(name: "Snow",  defaultValue: 0.50, units: nil),
            ],
            renderScale: 0.6,   // additive glows on dark water; tentacles keep a pixel-relative width
            colorPresets: [
                ColorPreset(name: "Abyss",
                            shadow: SIMD4<Float>(0.12, 0.52, 1.00, 1),
                            mid:    SIMD4<Float>(0.14, 0.62, 1.00, 1),
                            hot:    SIMD4<Float>(1.00, 0.50, 0.62, 1)),
                ColorPreset(name: "Lagoon",
                            shadow: SIMD4<Float>(0.04, 0.70, 0.56, 1),
                            mid:    SIMD4<Float>(0.36, 1.00, 0.76, 1),
                            hot:    SIMD4<Float>(1.00, 0.86, 0.42, 1)),
                ColorPreset(name: "Sea nettle",
                            shadow: SIMD4<Float>(0.08, 0.34, 0.90, 1),
                            mid:    SIMD4<Float>(1.00, 0.56, 0.18, 1),
                            hot:    SIMD4<Float>(1.00, 0.30, 0.24, 1)),
                ColorPreset(name: "Ultraviolet",
                            shadow: SIMD4<Float>(0.30, 0.14, 0.90, 1),
                            mid:    SIMD4<Float>(0.76, 0.36, 1.00, 1),
                            hot:    SIMD4<Float>(0.36, 1.00, 0.90, 1)),
                ColorPreset(name: "Crimson",
                            shadow: SIMD4<Float>(0.52, 0.06, 0.14, 1),
                            mid:    SIMD4<Float>(1.00, 0.30, 0.34, 1),
                            hot:    SIMD4<Float>(1.00, 0.80, 0.56, 1)),
                ColorPreset(name: "Ghost",
                            shadow: SIMD4<Float>(0.26, 0.32, 0.42, 1),
                            mid:    SIMD4<Float>(0.82, 0.90, 1.00, 1),
                            hot:    SIMD4<Float>(0.76, 0.80, 1.00, 1)),
            ],
            colorLabels: ["WATER", "BELL", "HEART"]
        ),
        ShaderEntry(
            fragmentFunction: "fs25_lanterns",
            shortLabel: "Lanterns",
            num: "SURFACE 25",
            sub: "Paper lanterns over still water",
            title: "Sky lanterns",
            emWord: "lanterns",
            desc: "Paper lanterns lift off a far shore and climb into the dusk, each flame doubled in the still water below. Your cursor is a breeze that leans them and ruffles the reflection; click to release one of your own.",
            params: [("paper", "rice, oiled"), ("fuel", "wax, 12 min"), ("ascent", "0.4 m/s")],
            options: [
                ShaderOption(name: "Lanterns", defaultValue: 1.00, units: nil),
                ShaderOption(name: "Rise",     defaultValue: 0.50, units: nil),
                ShaderOption(name: "Ripple",   defaultValue: 0.50, units: nil),
                ShaderOption(name: "Glow",     defaultValue: 0.50, units: nil),
            ],
            renderScale: 0.55,   // soft glows; lantern edges and stars are pixel-relative
            colorPresets: [
                ColorPreset(name: "Dusk",
                            shadow: SIMD4<Float>(0.32, 0.34, 1.00, 1),
                            mid:    SIMD4<Float>(1.00, 0.45, 0.16, 1),
                            hot:    SIMD4<Float>(1.00, 0.54, 0.13, 1)),
                ColorPreset(name: "Sakura",
                            shadow: SIMD4<Float>(0.46, 0.30, 0.86, 1),
                            mid:    SIMD4<Float>(1.00, 0.52, 0.72, 1),
                            hot:    SIMD4<Float>(1.00, 0.58, 0.70, 1)),
                ColorPreset(name: "Jade",
                            shadow: SIMD4<Float>(0.08, 0.44, 0.58, 1),
                            mid:    SIMD4<Float>(0.40, 0.94, 0.62, 1),
                            hot:    SIMD4<Float>(0.56, 1.00, 0.52, 1)),
                ColorPreset(name: "Ember",
                            shadow: SIMD4<Float>(0.52, 0.16, 0.30, 1),
                            mid:    SIMD4<Float>(1.00, 0.30, 0.10, 1),
                            hot:    SIMD4<Float>(1.00, 0.34, 0.08, 1)),
                ColorPreset(name: "Midnight",
                            shadow: SIMD4<Float>(0.14, 0.24, 0.90, 1),
                            mid:    SIMD4<Float>(0.24, 0.44, 1.00, 1),
                            hot:    SIMD4<Float>(1.00, 0.86, 0.56, 1)),
                ColorPreset(name: "Frost",
                            shadow: SIMD4<Float>(0.30, 0.46, 0.90, 1),
                            mid:    SIMD4<Float>(0.66, 0.86, 1.00, 1),
                            hot:    SIMD4<Float>(0.76, 0.90, 1.00, 1)),
            ],
            colorLabels: ["SKY", "HORIZON", "PAPER"]
        ),
        ShaderEntry(
            fragmentFunction: "fs26_sea",
            shortLabel: "Moonlit sea",
            num: "SURFACE 26",
            sub: "Night swell, specular glitter",
            title: "Moonlit sea",
            emWord: "sea",
            desc: "A slow swell rolls in under a low moon and a sky of faint stars, and a path of glitter runs across the water to your feet. The cursor carries the moon along the horizon; click and a fish jumps, leaving rings to spread and settle.",
            params: [("swell", "0.2 Hz"), ("moon", "waxing, 2°"), ("wind", "Beaufort 1")],
            options: [
                ShaderOption(name: "Swell",     defaultValue: 0.50, units: nil),
                ShaderOption(name: "Moon size", defaultValue: 0.50, units: nil),
                ShaderOption(name: "Clouds",    defaultValue: 0.50, units: nil),
                ShaderOption(name: "Stars",     defaultValue: 0.50, units: nil),
            ],
            renderScale: 0.5,   // soft sky and water; glitter holds up
            colorPresets: [
                ColorPreset(name: "Moonlight",
                            shadow: SIMD4<Float>(0.46, 0.67, 1.00, 1),
                            mid:    SIMD4<Float>(1.00, 0.96, 0.88, 1),
                            hot:    SIMD4<Float>(0.67, 0.79, 1.00, 1)),
                ColorPreset(name: "Dusk",
                            shadow: SIMD4<Float>(1.00, 0.60, 0.82, 1),
                            mid:    SIMD4<Float>(1.00, 0.84, 0.66, 1),
                            hot:    SIMD4<Float>(1.00, 0.62, 0.52, 1)),
                ColorPreset(name: "Harvest moon",
                            shadow: SIMD4<Float>(0.52, 0.52, 0.80, 1),
                            mid:    SIMD4<Float>(1.00, 0.72, 0.36, 1),
                            hot:    SIMD4<Float>(0.96, 0.66, 0.42, 1)),
                ColorPreset(name: "Aurora",
                            shadow: SIMD4<Float>(0.30, 0.88, 0.78, 1),
                            mid:    SIMD4<Float>(0.86, 1.00, 0.92, 1),
                            hot:    SIMD4<Float>(0.40, 1.00, 0.68, 1)),
                ColorPreset(name: "Ink",
                            shadow: SIMD4<Float>(0.30, 0.30, 0.34, 1),
                            mid:    SIMD4<Float>(0.96, 0.96, 0.96, 1),
                            hot:    SIMD4<Float>(0.70, 0.70, 0.74, 1)),
            ],
            colorLabels: ["NIGHT", "MOON", "HALO"]
        ),
        ShaderEntry(
            fragmentFunction: "fs27_zen",
            shortLabel: "Zen garden",
            num: "SURFACE 27",
            sub: "Karesansui raked sand",
            title: "Zen garden",
            emWord: "garden",
            desc: "Raked gravel in low late-afternoon sun: furrows ring three stones and run straight across the rest. Your cursor is a rake, combing grooves that slowly heal back into the pattern; click to set down a pebble and watch it get its own rings.",
            params: [("gravel", "shirakawa-suna"), ("tines", "5 × 6 cm"), ("sun", "17° · west")],
            options: [
                ShaderOption(name: "Relief",     defaultValue: 0.50, units: nil),
                ShaderOption(name: "Sun height", defaultValue: 0.50, units: nil),
                ShaderOption(name: "Leaf shade", defaultValue: 0.50, units: nil),
                ShaderOption(name: "Heal time",  defaultValue: 0.50, units: nil),
            ],
            renderScale: 0.5,   // furrows are ~13 px apart even here
            colorPresets: [
                ColorPreset(name: "Late afternoon",
                            shadow: SIMD4<Float>(0.80, 0.76, 0.68, 1),
                            mid:    SIMD4<Float>(0.52, 0.50, 0.46, 1),
                            hot:    SIMD4<Float>(1.00, 0.80, 0.58, 1)),
                ColorPreset(name: "White gravel",
                            shadow: SIMD4<Float>(0.90, 0.89, 0.86, 1),
                            mid:    SIMD4<Float>(0.44, 0.44, 0.44, 1),
                            hot:    SIMD4<Float>(1.00, 0.94, 0.86, 1)),
                ColorPreset(name: "Slate",
                            shadow: SIMD4<Float>(0.30, 0.31, 0.33, 1),
                            mid:    SIMD4<Float>(0.60, 0.61, 0.62, 1),
                            hot:    SIMD4<Float>(1.00, 0.86, 0.70, 1)),
                ColorPreset(name: "Rose evening",
                            shadow: SIMD4<Float>(0.84, 0.77, 0.75, 1),
                            mid:    SIMD4<Float>(0.46, 0.40, 0.42, 1),
                            hot:    SIMD4<Float>(1.00, 0.72, 0.64, 1)),
                ColorPreset(name: "Snow",
                            shadow: SIMD4<Float>(0.97, 0.98, 1.00, 1),
                            mid:    SIMD4<Float>(0.36, 0.37, 0.40, 1),
                            hot:    SIMD4<Float>(0.92, 0.94, 1.00, 1)),
                ColorPreset(name: "Moonlit",
                            shadow: SIMD4<Float>(0.62, 0.66, 0.74, 1),
                            mid:    SIMD4<Float>(0.40, 0.42, 0.46, 1),
                            hot:    SIMD4<Float>(0.42, 0.52, 0.72, 1)),
            ],
            colorLabels: ["GRAVEL", "STONE", "SUN"]
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

    // Colour presets. The values are in NSColorWell-friendly 0..1 sRGB space;
    // the flow field boosts them internally for HDR pop through the tonemap.
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

    // Lava lamp: solvent / wax / glow.
    static let lavaPresets: [ColorPreset] = [
        ColorPreset(name: "Classic",
                    shadow: SIMD4<Float>(0.34, 0.04, 0.12, 1),
                    mid:    SIMD4<Float>(0.98, 0.32, 0.06, 1),
                    hot:    SIMD4<Float>(1.00, 0.74, 0.30, 1)),
        ColorPreset(name: "Lagoon",
                    shadow: SIMD4<Float>(0.03, 0.10, 0.26, 1),
                    mid:    SIMD4<Float>(0.10, 0.78, 0.72, 1),
                    hot:    SIMD4<Float>(0.70, 1.00, 0.92, 1)),
        ColorPreset(name: "Ultraviolet",
                    shadow: SIMD4<Float>(0.12, 0.04, 0.30, 1),
                    mid:    SIMD4<Float>(1.00, 0.26, 0.62, 1),
                    hot:    SIMD4<Float>(1.00, 0.76, 0.92, 1)),
        ColorPreset(name: "Absinthe",
                    shadow: SIMD4<Float>(0.03, 0.14, 0.10, 1),
                    mid:    SIMD4<Float>(0.52, 0.92, 0.14, 1),
                    hot:    SIMD4<Float>(0.94, 1.00, 0.62, 1)),
        ColorPreset(name: "Sunset",
                    shadow: SIMD4<Float>(0.50, 0.30, 0.04, 1),
                    mid:    SIMD4<Float>(0.86, 0.10, 0.08, 1),
                    hot:    SIMD4<Float>(1.00, 0.70, 0.36, 1)),
        ColorPreset(name: "Smoke",
                    shadow: SIMD4<Float>(0.11, 0.11, 0.13, 1),
                    mid:    SIMD4<Float>(0.80, 0.78, 0.74, 1),
                    hot:    SIMD4<Float>(1.00, 0.96, 0.88, 1)),
    ]

    // Shaders without a palette ignore col0..2, so white is as good as anything.
    static func defaultColorSet(for shaderIndex: Int)
        -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    {
        guard entries.indices.contains(shaderIndex), let p = entries[shaderIndex].colorPresets.first else {
            return (SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(1, 1, 1, 1))
        }
        return (p.shadow, p.mid, p.hot)
    }
}
