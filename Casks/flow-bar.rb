cask "flow-bar" do
  version "0.3.0"
  # sha256 of the SOURCE TARBALL (not a release zip). release.yml computes it
  # with `curl -sL <url> | shasum -a 256` and rewrites this line on every tag.
  sha256 "c1d8f9f69c19680111f57d31ce4d7f0f272d032c985bb557be4143c25294782a"

  url "https://github.com/pa/flow-bar/archive/refs/tags/v#{version}.tar.gz",
      verified: "github.com/pa/flow-bar/"
  name "flow-bar"
  desc "Menubar app for the flow dashboard and task switcher"
  homepage "https://github.com/pa/flow-bar"

  # Source builds need a Swift 6 toolchain, which Apple ships only in Xcode /
  # Command Line Tools 16+ — and those require macOS 14.5+. So the old :ventura
  # floor isn't buildable regardless of what the deployment target says.
  depends_on macos: :sequoia

  # This cask COMPILES flow-bar rather than downloading a prebuilt binary.
  #
  # Why: SwiftUI picks its appearance from the macOS SDK the binary was *linked
  # against*, not the OS it runs on. A CI-built binary therefore renders in
  # compatibility mode on any newer macOS, forever. Building here is what makes
  # the app look native on whatever you're running.
  #
  # Why a cask and not a formula: formula installs run inside Homebrew's
  # sandbox, which denies reads of ~/Library/Keychains and writes to
  # /Applications. A formula could therefore neither sign the app with a stable
  # identity (which is what keeps the macOS Automation grant alive across
  # upgrades) nor install a real .app. A cask `installer script:` runs
  # unsandboxed with the real $HOME.
  #
  # Ordering: Homebrew runs artifacts in AbstractArtifact.sort_order, where
  # Installer precedes App — so despite `app` appearing first here, the build
  # script runs before the bundle is moved into place.
  #
  # No `auto_updates true`: Homebrew owns updates on this channel, and
  # auto_updates would make `brew upgrade` skip the cask unless given --greedy.
  # The in-app updater stands down here (see Updater.swift) and points at
  # `brew upgrade` instead.
  #
  # Keep build logic in build-app.sh, not here — `installer script:` is an
  # escape hatch Homebrew is gradually narrowing, and a thin cask keeps a
  # future move cheap.
  # Paths are prefixed with the tarball's top-level directory. Homebrew only
  # flattens a single extracted child when it is NOT a directory
  # (UnpackStrategy#extract_nestedly), so GitHub's "<repo>-<version>/" wrapper
  # survives staging and both paths must include it.
  #
  # `print_stdout` is deliberately absent: Installer hardcodes it as an override,
  # so passing it explicitly errors with "arguments will be ignored (overridden)".
  app "flow-bar-#{version}/flow-bar.app"
  installer script: {
    executable: "flow-bar-#{version}/build-app.sh",
    args:       ["--version", version.to_s, "--channel", "homebrew-source", "--sign-local"],
  }

  uninstall quit: "cloud.facets.flow-bar"

  zap trash: [
    "~/Library/Application Support/flow-bar",
    "~/Library/Caches/cloud.facets.flow-bar",
    "~/Library/Logs/flow-bar.log",
    "~/Library/Preferences/cloud.facets.flow-bar.plist",
  ]

  caveats <<~EOS
    flow-bar is a companion to the `flow` CLI — install it from
    https://github.com/Facets-cloud/flow and make sure it's on your PATH.

    This cask COMPILES flow-bar on your machine (about a minute) so the app
    links against your macOS SDK and looks native on your OS. It needs Xcode or
    the Command Line Tools:

      xcode-select --install

    The build signs flow-bar with a self-signed certificate created once in a
    dedicated "flow-bar-signing" keychain. That keeps its code identity stable,
    so the macOS permission to control your terminal survives every upgrade.
    Nothing is sent anywhere and the key never leaves your Mac.

    After a macOS major upgrade, rebuild so the app picks up the new SDK:

      brew reinstall --cask flow-bar
  EOS
end
