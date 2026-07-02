import AppKit
import Foundation

/// Lightweight in-app updater: checks GitHub Releases, and (on request) downloads
/// the release zip, verifies it's signed with our persistent cert, swaps the app
/// bundle, and relaunches. No brew, no Gatekeeper prompt (an in-app URLSession
/// download isn't quarantined), and — because every release shares one signing
/// identity — no permission re-grant.
enum Updater {
    static let latestAPI = "https://api.github.com/repos/pa/flow-bar/releases/latest"
    /// The app is signed with this identity in CI; we refuse to install anything
    /// that isn't (tamper / wrong-source guard, our stand-in for notarization).
    static let expectedAuthority = "flow-bar-signing"

    struct Release: Sendable { let version: String; let zipURL: URL }

    /// The running app's version (CFBundleShortVersionString), stamped at build.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Fetch the latest release (version + flow-bar.zip asset URL) from GitHub.
    static func fetchLatest() async -> Release? {
        guard let url = URL(string: latestAPI) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("flow-bar", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]]
        else { return nil }
        let asset = assets.first { ($0["name"] as? String) == "flow-bar.zip" }
        guard let s = asset?["browser_download_url"] as? String, let zip = URL(string: s)
        else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: v, zipURL: zip)
    }

    enum InstallError: Error, CustomStringConvertible {
        case download, unzip, missingApp, signature, notWritable
        var description: String {
            switch self {
            case .download:   return "download failed"
            case .unzip:      return "couldn’t unpack the update"
            case .missingApp: return "update archive had no app"
            case .signature:  return "update isn’t signed by flow-bar — refused"
            case .notWritable: return "can’t write to \(Bundle.main.bundlePath) — move flow-bar to /Applications"
            }
        }
    }

    /// Download → unzip → verify signature → swap bundle → relaunch. On success
    /// the app quits (a detached helper swaps + reopens it); throws otherwise.
    static func install(_ release: Release) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("flow-bar-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("flow-bar.zip")

        guard let (data, resp) = try? await URLSession.shared.data(from: release.zipURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              (try? data.write(to: zipPath)) != nil
        else { throw InstallError.download }

        let unpack = work.appendingPathComponent("unpack")
        guard runExit("/usr/bin/ditto", ["-x", "-k", zipPath.path, unpack.path]) == 0
        else { throw InstallError.unzip }
        let newApp = unpack.appendingPathComponent("flow-bar.app")
        guard fm.fileExists(atPath: newApp.path) else { throw InstallError.missingApp }

        // Verify the downloaded app carries our signing identity.
        let out = runOutput("/usr/bin/codesign", ["-dvv", newApp.path])
        guard out.contains("Authority=\(expectedAuthority)") else { throw InstallError.signature }

        let dest = Bundle.main.bundlePath
        // Fail early if we can't write where the app lives (e.g. read-only volume).
        guard fm.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent)
        else { throw InstallError.notWritable }

        // Detached helper: wait for us to quit, swap the bundle (with rollback),
        // relaunch, and clean up. Then we terminate so it can proceed.
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = "\(dest).old-\(pid)"
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        mv "\(dest)" "\(backup)" 2>/dev/null || true
        if mv "\(newApp.path)" "\(dest)"; then
          rm -rf "\(backup)"
          xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null || true
          open "\(dest)"
        else
          mv "\(backup)" "\(dest)" 2>/dev/null || true
          open "\(dest)"
        fi
        rm -rf "\(work.path)"
        """
        let scriptPath = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        _ = runExit("/bin/chmod", ["+x", scriptPath.path])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptPath.path]
        try p.run()   // detached; keeps running after we exit
        await MainActor.run { NSApp.terminate(nil) }
    }

    // MARK: helpers

    @discardableResult
    private static func runExit(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func runOutput(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe   // codesign -dvv writes to stderr
        do {
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        } catch { return "" }
    }
}
