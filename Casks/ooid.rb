cask "ooid" do
  # ponytail: :latest needs no per-release bump because Sparkle updates the app.
  # Pin version and sha256 if this moves to homebrew/cask, which also needs notarization.
  version :latest
  sha256 :no_check

  url "https://github.com/magicsk/ooid/releases/latest/download/Ooid.dmg"
  name "Ooid"
  desc "Interactive GPU shader wallpapers and screensaver"
  homepage "https://github.com/magicsk/ooid"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Ooid.app"

  zap trash: [
    "~/Library/Caches/com.magicsk.Ooid",
    "~/Library/HTTPStorages/com.magicsk.Ooid",
    "~/Library/Preferences/com.magicsk.Ooid.plist",
  ]

  caveats <<~EOS
    Ooid is ad-hoc signed, not notarized, so macOS blocks its first launch.
    Try to open it, then choose Open Anyway in System Settings > Privacy & Security, or run:
      xattr -dr com.apple.quarantine #{appdir}/Ooid.app
  EOS
end
