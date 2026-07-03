cask "flow-bar" do
  version "0.1.14"
  sha256 "0e4a949599669c13c22c47082e0aa53301ef2a8a7a33566893dc9ea6135e7c1b"

  url "https://github.com/pa/flow-bar/releases/download/v#{version}/flow-bar.zip"
  name "flow-bar"
  desc "Lightweight macOS menubar app for the flow dashboard + task switcher"
  homepage "https://github.com/pa/flow-bar"

  depends_on macos: :ventura # macOS 13+ (minimum)

  # flow-bar updates itself in-app (checks GitHub Releases, downloads + swaps
  # the bundle), so Homebrew installs it once and leaves version bumps to the
  # app rather than fighting the self-updater.
  auto_updates true

  app "flow-bar.app"

  caveats <<~EOS
    flow-bar is a companion to the `flow` CLI — install it from
    https://github.com/Facets-cloud/flow and make sure it's on your PATH.

    This build is not yet notarized, so macOS Gatekeeper will block the first
    launch. Allow it with:

      xattr -dr com.apple.quarantine "#{appdir}/flow-bar.app"

    then open flow-bar again.
  EOS
end
