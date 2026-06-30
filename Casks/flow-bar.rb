cask "flow-bar" do
  version "0.1.3"
  sha256 "0e32689ce22e06a7f0900dd90d9f2b2095403c7166ccbf3f226d0847b2748d1f"

  url "https://github.com/pa/flow-bar/releases/download/v#{version}/flow-bar.zip"
  name "flow-bar"
  desc "Lightweight macOS menubar app for the flow dashboard + task switcher"
  homepage "https://github.com/pa/flow-bar"

  depends_on macos: :ventura # macOS 13+ (minimum)

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
