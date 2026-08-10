# Cask template for the tap SebastianMoyano/homebrew-chinchilla.
# Copy to Casks/chinchilla.rb in that repo on every release and replace the
# two PLACEHOLDER values below — nothing else changes between versions.
cask "chinchilla" do
  version "0.20.2"                                                            # PLACEHOLDER: CFBundleShortVersionString of the release
  sha256 "9e1854a9d90c6dc7a51f3226b818d2a881e68f8857f6ffbec405fcb14239ba9e"  # PLACEHOLDER: shasum -a 256 dist/Chinchilla-<version>.dmg

  url "https://github.com/SebastianMoyano/chinchilla/releases/download/v#{version}/Chinchilla-#{version}.dmg",
      verified: "github.com/SebastianMoyano/chinchilla/"
  name "Chinchilla"
  desc "Native macOS cleaning and maintenance app"
  homepage "https://github.com/SebastianMoyano/chinchilla"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Matches LSMinimumSystemVersion in packaging/Info.plist.
  depends_on macos: ">= :sonoma"

  app "Chinchilla.app"
  # The app binary is also the CLI (scan/clean/history/status).
  binary "#{appdir}/Chinchilla.app/Contents/MacOS/Chinchilla", target: "chinchilla"

  uninstall quit:       "com.sebastian.chinchilla",
            launchctl:  "com.sebastian.chinchilla.autoclean"

  # Full Disk Access is granted to the bundle, so a reinstall keeps it; only
  # `zap` should erase the audit log the user may still need.
  zap trash: [
    "~/Library/Application Support/Chinchilla",
    "~/Library/Caches/com.sebastian.chinchilla",
    "~/Library/HTTPStorages/com.sebastian.chinchilla",
    "~/Library/LaunchAgents/com.sebastian.chinchilla.autoclean.plist",
    "~/Library/Logs/Chinchilla",
    "~/Library/Preferences/com.sebastian.chinchilla.plist",
  ]
end
