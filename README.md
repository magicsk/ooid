# Ooid

22 interactive fragment-shader wallpapers for macOS, written in Swift + Metal for
raw GPU efficiency. Use them in a window, as your desktop wallpaper or as a screensaver.

## Install

Requires an Apple Silicon Mac running macOS 13 or later.

**Homebrew**

```sh
brew tap magicsk/ooid https://github.com/magicsk/ooid
brew install --cask magicsk/ooid/ooid
```

**Manual:** download `Ooid.dmg` from the
[latest release](https://github.com/magicsk/ooid/releases/latest) and drag Ooid to Applications.

**First launch:** Ooid is ad-hoc signed, not notarized, so macOS blocks it the first
time. Try to open it, then choose **Open Anyway** in System Settings → Privacy &
Security, or run:

```sh
xattr -d com.apple.quarantine /Applications/Ooid.app
```

**Updates:** Ooid updates itself using [Sparkle](https://sparkle-project.org). You can
also use **Ooid → Check for Updates…**. Homebrew leaves updates to Sparkle, so
`brew upgrade` won't change the app.

## Why native Metal

Ooid began as a WebGL prototype called Shader Wallpapers, which hammered the GPU
through a browser-level abstraction. On the same pixels, a direct Metal path gives us:

- **Zero driver overhead** — Metal's command encoder goes straight to the GPU
  scheduler; no GL state machine, no context switching.
- **Unified memory on Apple Silicon** — uniforms are CPU-visible and GPU-visible
  without copies (`.storageModeShared`).
- **Compile once, reuse forever** — pipeline states are built at launch and
  cached; subsequent runs load from the on-disk Metal shader cache.
- **Precise frame pacing** — `MTKView` ties to the actual display link, pausing
  automatically when the window is occluded or miniaturised.

## GPU-efficiency choices (vs. the web prototype)

| Concern                | Web prototype                | Metal port |
|------------------------|------------------------------|------------|
| Vertices per frame     | 4 (triangle strip quad)      | **3** (fullscreen triangle, no vertex buffer) |
| Pipeline compile       | every shader at load         | same, but cached in Metal shader cache after first run |
| Uniform upload         | `gl.uniformNf` per draw      | `set*Bytes` copy into the command buffer — no ring, no fences |
| CPU→GPU sync           | implicit in WebGL            | none needed: the 3-deep drawable pool paces the CPU |
| MSAA / depth / stencil | `antialias: false`           | `sampleCount=1`, `depthStencilPixelFormat=.invalid` |
| Load action            | default = load               | `.dontCare` (every shader writes every pixel) |
| Blending               | implicit                     | explicitly disabled |
| Precision              | `highp`                      | `-ffast-math` enabled via `MTLCompileOptions.fastMathEnabled` |
| Occlusion              | browser keeps rendering      | paused on `didChangeOcclusionState` + `didMiniaturize` |
| Vsync                  | driver-controlled            | `CAMetalLayer.displaySyncEnabled = true` |
| Framebuffer copy       | intermediate surface         | `framebufferOnly = true`, tile memory only |
| Swapchain depth        | varies                       | `maximumDrawableCount = 3` (lockstep with the uniform ring) |

## Controls

- **Mouse move** — each shader reacts differently (gravity well, thermal,
  pinch, tilt, magnet, heat, black hole, …)
- **Click** — emits a shockwave in whatever medium the current shader models
- **1…9, 0** — jump directly to shader 1…9 / 10 (11–22: arrows or the nav)
- **Left / Right arrow, Space** — cycle
- **F / Escape** — toggle fullscreen
- **Q** — quit

## Build & run

```sh
swift run -c release
```

`swift run -c release Ooid --bench [--png DIR]` renders every shader offscreen and
prints its GPU ms/frame against the 120 fps budget (and optionally a snapshot).

The first launch compiles the shaders (~100 ms); subsequent launches hit the
Metal shader cache and start instantly.

## Releasing

Push a version tag. The [release workflow](.github/workflows/release.yml) builds the
DMG, signs the update, and publishes the GitHub release that Sparkle and Homebrew read.

```sh
git tag v1.2.3 && git push origin v1.2.3
```

Tags must be numeric (`v1.2.3`) and always increase, because Sparkle compares them to
decide what counts as an update.

The workflow needs the `SPARKLE_ED_KEY` repository secret, which is the private key
from `generate_keys -x` (in `.build/artifacts/sparkle/Sparkle/bin/` after a build). Back
it up: without it you can't ship updates to existing installs.

## Project layout

```
Ooid/
├── Package.swift
├── Casks/ooid.rb                 # Homebrew cask
├── Scripts/build-dmg.sh          # Builds the .app and DMG
└── Sources/Ooid/
    ├── main.swift                # NSApp bootstrap, window, menu, updater
    ├── AppResources.swift        # Resource lookup that avoids Bundle.module
    ├── SettingsWindow.swift      # Settings window
    ├── Renderer.swift            # MTKViewDelegate, pipeline cache, uniform ring
    ├── MetalContentView.swift    # Custom MTKView: input + occlusion pause
    ├── OverlayView.swift         # AppKit overlay (brand / stage / nav)
    ├── ShaderCatalog.swift       # per-shader metadata: title, copy, params, render scale
    ├── Bench.swift               # `--bench`: offscreen GPU timing through the real Renderer
    └── Shaders.metal             # All shaders (and their pre-passes) in Metal Shading Language
```

All shaders share one file so helper functions and the noise toolkit are
compiled once. Each shader prefixes its private helpers (`s1_*`, `s2_*`, …) to
avoid collisions.

## License

[GPL-3.0](LICENSE). Sparkle is bundled under [its own license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).
