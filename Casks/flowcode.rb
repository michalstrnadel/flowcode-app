# Casks/flowcode.rb — Homebrew cask for flowcode.
#
# TEMPLATE: `version` and `sha256` are rewritten by CI (release.yml) on every
# tagged release. Distributed as a notarized universal .zip (no DMG, per PLAN.md).
#
# Install:  brew install --cask <tap>/flowcode
#
cask "flowcode" do
  version "0.1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  arch arm: "arm64", intel: "x86_64"

  url "https://github.com/mbailey/flowcode/releases/download/v#{version}/flowcode-#{version}-#{arch}.zip",
      verified: "github.com/mbailey/flowcode/"
  name "flowcode"
  desc "Real-time, interruptible voice for Claude Code"
  homepage "https://github.com/mbailey/flowcode"

  # macOS 14+ (Sonoma) — matches Package.swift platforms + Info.plist LSMinimumSystemVersion.
  depends_on macos: ">= :sonoma"

  # Sparkle handles in-app updates; tell Homebrew not to fight it.
  auto_updates true

  app "flowcode.app"

  zap trash: [
    "~/Library/Application Support/flowcode",
    "~/Library/Caches/cz.slevomat.flowcode",
    "~/Library/HTTPStorages/cz.slevomat.flowcode",
    "~/Library/Preferences/cz.slevomat.flowcode.plist",
    "~/Library/Saved Application State/cz.slevomat.flowcode.savedState",
    # Sparkle update sandbox.
    "~/Library/Caches/cz.slevomat.flowcode.ShipIt",
  ]
end
