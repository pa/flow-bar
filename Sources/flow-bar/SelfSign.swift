import AppKit
import Foundation

/// Keeps flow-bar's code identity stable so the macOS Automation (TCC) grant
/// survives upgrades.
///
/// **Why this exists.** `FlowClient.spawnDisclaimed` deliberately does *not*
/// disclaim responsibility for the AppleScript terminal backends (iTerm,
/// Terminal, Warp, Ghostty) so macOS shows a normal, grantable "flow-bar wants
/// to control <app>" prompt. That means flow-bar itself owns the grant — and
/// TCC keys the grant to the bundle's Designated Requirement, not its path.
/// An ad-hoc signature's DR is the code hash, which changes on every single
/// build, so an ad-hoc app loses the grant on every upgrade and `flow do`
/// starts failing with -1743 for no visible reason.
///
/// A per-machine self-signed identity gives a stable, hash-pinned DR
/// (`identifier "cloud.facets.flow-bar" and certificate leaf = H"…"`) that is
/// byte-identical across rebuilds. The certificate does **not** need to be a
/// trusted root: trust is required to *validate* a signature, not to produce
/// one.
///
/// `build-app.sh --sign-local` normally does this at install time. This is the
/// safety net for bundles that arrive unsigned or get re-signed by something
/// else — without it, a single ad-hoc build silently costs the user their grant.
///
/// **Why it relaunches instead of re-signing in place.** Re-signing the
/// executable of a *running* bundle is not safe: the kernel validates
/// lazily-faulted pages against the code directory captured at `exec`, so
/// rewriting `Contents/MacOS/flow-bar` underneath ourselves can get us SIGKILLed
/// for a code-signing violation. Instead we use the detached-helper pattern
/// already proven in `Updater.swift`: spawn a script that waits for us to exit,
/// signs the bundle, and reopens it. Costs one extra relaunch, on first run only.
enum SelfSign {
    static let identity = "flow-bar Code Signing"
    private static let keychain = "flow-bar-signing.keychain"
    private static let keychainPassword = "flow-bar-signing"
    /// Loop guard. Must be a file, not an env var: we relaunch via `open`, which
    /// hands off to LaunchServices and does NOT pass the environment through — so
    /// an env-var guard would never reach the new process, and a bundle that
    /// fails to sign would relaunch forever.
    private static var attemptMarker: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/flow-bar/.selfsign-attempt")
    }
    /// Long enough to cover a relaunch, short enough that a genuine retry is
    /// possible on the next launch (e.g. after the user fixes their keychain).
    private static let retryCooldown: TimeInterval = 300

    /// Call early in `applicationDidFinishLaunching`. Returns true if it is
    /// relaunching the app (caller should stop doing setup work).
    /// Main-actor isolated: called from `applicationDidFinishLaunching` and
    /// terminates the app on the relaunch path.
    @MainActor
    @discardableResult
    static func bootstrap() -> Bool {
        // Prebuilt downloads carry the CI identity, which is already stable and
        // is what Updater verifies against. Never re-sign those.
        guard AppInfo.channel != "github-release" else { return false }

        let bundle = Bundle.main.bundlePath
        guard !isSigned(bundle, with: identity) else { return false }

        // We're here and unsigned. If we *just* tried, the attempt didn't take —
        // run ad-hoc rather than relaunching forever.
        if recentlyAttempted() {
            NSLog("flow-bar: still not signed with '\(identity)'; running ad-hoc. "
                  + "Automation permission may need re-granting after upgrades.")
            return false
        }
        recordAttempt()

        if !certExists() {
            guard createCert() else {
                NSLog("flow-bar: could not create a signing cert; running ad-hoc.")
                return false
            }
        }
        // The bundle must not be signed while we're executing from it, so hand
        // the work to a helper that waits for us to exit first.
        guard relaunchSigned(bundle) else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// Whether this bundle currently carries our stable identity. Drives the
    /// Settings "Update protection" row.
    static var isProtected: Bool { isSigned(Bundle.main.bundlePath, with: identity) }

    // MARK: - Steps

    private static func isSigned(_ path: String, with identity: String) -> Bool {
        // `codesign -dvvv` prints the authority chain to stderr.
        run("/usr/bin/codesign", ["-dvvv", path]).output.contains("Authority=\(identity)")
    }

    private static func certExists() -> Bool {
        // NOT `-v`: a self-signed codesigning cert always reports
        // CSSMERR_TP_NOT_TRUSTED, so the valid-only listing hides it even though
        // `codesign` signs with it fine. Using `-v` here would make us think the
        // cert is missing and destructively recreate it — minting a *new* leaf,
        // changing the DR, and losing the grant on every single launch.
        run("/usr/bin/security", ["find-identity", "-p", "codesigning"]).output.contains(identity)
    }

    private static func createCert() -> Bool {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-bar-cert-\(UUID().uuidString).sh")
        do { try certScript.write(to: url, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        return run("/bin/bash", [url.path]).status == 0 && certExists()
    }

    /// Detached helper: wait for us to quit, sign the bundle, reopen it.
    private static func relaunchSigned(_ bundle: String) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-bar-selfsign-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        # Unlock so codesign can reach the key without a GUI prompt; without
        # this it fails with errSecInternalComponent.
        security unlock-keychain -p "\(keychainPassword)" "\(keychain)" 2>/dev/null || true
        codesign --force --deep --sign "\(identity)" "\(bundle)" >/dev/null 2>&1
        open "\(bundle)"
        rm -rf "\(dir.path)"
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("sign.sh")
            try script.write(to: path, atomically: true, encoding: .utf8)
            _ = run("/bin/chmod", ["+x", path.path])

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [path.path]
            try p.run()   // detached; keeps running after we exit
            return true
        } catch {
            NSLog("flow-bar: could not start the signing helper: \(error)")
            return false
        }
    }

    // MARK: - Loop guard

    private static func recentlyAttempted() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: attemptMarker.path),
              let when = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(when) < retryCooldown
    }

    private static func recordAttempt() {
        let dir = attemptMarker.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: attemptMarker)
        // `write` preserves an existing mtime on some paths; stamp it explicitly.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: attemptMarker.path)
    }

    // MARK: - Process helper

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Non-interactive per-machine cert creation. Mirrors
    /// `scripts/create-signing-cert.sh` — keep the two in step.
    ///
    /// The keychain password is hardcoded on purpose: it protects nothing but
    /// local code-identity continuity, and prompting would break both a
    /// `brew install` and a first launch. Please don't "fix" it.
    private static let certScript = """
    set -euo pipefail
    IDENTITY_NAME="flow-bar Code Signing"
    KEYCHAIN_NAME="flow-bar-signing.keychain"
    KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
    KEYCHAIN_PASSWORD="flow-bar-signing"
    if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then exit 0; fi
    # System LibreSSL, not a Homebrew OpenSSL 3.x: OpenSSL 3 writes a PKCS#12 MAC
    # that macOS's `security import` rejects with "MAC verification failed".
    OPENSSL="/usr/bin/openssl"
    P12_PASSWORD="flow-bar-p12"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<EOF
    [req]
    distinguished_name = dn
    x509_extensions = v3
    prompt = no
    [dn]
    CN = ${IDENTITY_NAME}
    [v3]
    basicConstraints = critical, CA:false
    keyUsage = critical, digitalSignature
    extendedKeyUsage = critical, codeSigning
    EOF
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
    "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY_NAME" -out "$WORK/identity.p12" -passout pass:"$P12_PASSWORD" >/dev/null 2>&1
    security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    security set-keychain-settings "$KEYCHAIN_NAME"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    security import "$WORK/identity.p12" -k "$KEYCHAIN_NAME" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true
    CURRENT="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
    if ! grep -q "$KEYCHAIN_NAME" <<<"$CURRENT"; then
        security list-keychains -d user -s "$KEYCHAIN_PATH" $CURRENT
    fi
    """
}
