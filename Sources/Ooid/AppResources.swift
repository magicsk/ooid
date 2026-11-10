import Foundation

// Resource lookup that never touches `Bundle.module`.
//
// Why: SwiftPM's auto-generated `Bundle.module` lazy-initialises by scanning
// a handful of candidate paths for the compiled resource bundle
// (`Ooid_Ooid.bundle`) and calls `fatalError` if none match. On macOS 26
// `Bundle(url:)` got stricter about what counts as a valid bundle — our
// flat SPM resource directory no longer passes validation, so the very
// first access to `Bundle.module` crashes the app at launch.
//
// This helper sidesteps the whole thing: it looks for resources in
// `Bundle.main` first (which works perfectly for the packaged `.app`,
// where we stage files flat into `Contents/Resources/`), then falls back
// to walking the SPM resource directory ourselves — using plain file-
// existence checks instead of `Bundle(url:)`, which macOS 26 rejects for
// flat SwiftPM bundles.
enum AppResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        let file = "\(name).\(ext)"
        for dir in candidateSearchDirs() {
            let candidate = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private final class Finder {}

    private static func candidateSearchDirs() -> [URL] {
        let bundleName = "Ooid_Ooid.bundle"
        let roots: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: Finder.self).resourceURL,
            Bundle(for: Finder.self).bundleURL.deletingLastPathComponent(),
        ]
        var dirs: [URL] = []
        for root in roots {
            guard let r = root else { continue }
            dirs.append(r.appendingPathComponent(bundleName))
            dirs.append(r.appendingPathComponent(bundleName).appendingPathComponent("Contents/Resources"))
            dirs.append(r)
        }
        return dirs
    }
}
