import AppKit
import FlowBarCore
import Foundation

/// A named FLOW_ROOT — switching the active profile points every flow command
/// flow-bar runs at that root.
struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var root: String  // absolute path (may contain ~)

    static let defaultID = "default"
    static var defaultRoot: String { NSHomeDirectory() + "/.flow" }
    static var defaultProfile: Profile {
        Profile(id: defaultID, name: "Default", root: defaultRoot)
    }
}

@MainActor
extension Store {
    private static let profilesKey = "profiles"
    private static let activeIDKey = "activeProfileID"

    var activeProfile: Profile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first ?? .defaultProfile
    }

    /// Load persisted profiles (seeding a Default), restore the active one,
    /// and publish the active root for FlowClient to read.
    func loadProfiles() {
        let decoded = (UserDefaults.standard.data(forKey: Self.profilesKey))
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        profiles = decoded.isEmpty ? [.defaultProfile] : decoded
        if !profiles.contains(where: { $0.id == Profile.defaultID }) {
            profiles.insert(.defaultProfile, at: 0)
        }
        let savedActive = UserDefaults.standard.string(forKey: Self.activeIDKey)
        activeProfileID = (savedActive.flatMap { id in profiles.first { $0.id == id }?.id }) ?? Profile.defaultID
        persistProfiles()
        syncActiveRoot()
    }

    func setActiveProfile(_ id: String) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        persistProfiles()
        syncActiveRoot()
        reloadForProfileSwitch()
    }

    /// Pick a folder (native panel), validate it looks like a flow root, then
    /// add + activate it.
    func addProfileViaPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Profile"
        panel.message = "Choose a flow root directory (contains flow.db)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let dbPath = url.appendingPathComponent("flow.db").path
        if !FileManager.default.fileExists(atPath: dbPath) {
            let alert = NSAlert()
            alert.messageText = "No flow.db found"
            alert.informativeText = "“\(url.lastPathComponent)” doesn't look like a flow root (no flow.db). Add it anyway?"
            alert.addButton(withTitle: "Add anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }

        // De-dup by path; if it exists, just activate it.
        if let existing = profiles.first(where: { ($0.root as NSString).expandingTildeInPath == url.path }) {
            setActiveProfile(existing.id)
            return
        }
        let profile = Profile(id: UUID().uuidString, name: url.lastPathComponent, root: url.path)
        profiles.append(profile)
        persistProfiles()
        setActiveProfile(profile.id)
    }

    func removeActiveProfile() {
        let id = activeProfileID
        guard id != Profile.defaultID else { return }  // never remove Default
        profiles.removeAll { $0.id == id }
        activeProfileID = Profile.defaultID
        persistProfiles()
        syncActiveRoot()
        reloadForProfileSwitch()
    }

    // MARK: Private

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
        UserDefaults.standard.set(activeProfileID, forKey: Self.activeIDKey)
    }

    private func syncActiveRoot() {
        UserDefaults.standard.set(activeProfile.root, forKey: activeFlowRootKey)
    }

    /// Active root changed — drop cached data and reload against the new root.
    private func reloadForProfileSwitch() {
        projectTasks = []
        ownerTasks = []
        browseTasks = []
        playbooks = []
        runs = []
        metrics = nil
        refresh()
        refreshMetrics()
    }
}
