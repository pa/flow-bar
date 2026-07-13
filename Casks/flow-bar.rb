cask "flow-bar" do
  version "0.2.1"
  sha256 "b10e568eb3711bc911493739ba4caf15ed26ea07d300da8706c7c6de77cf4534"

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
