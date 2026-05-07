import Foundation

/// Re-generates Quick Actions and Toolbar-Apps whenever the connection list
/// changes — but only for the integrations the user has actually installed.
/// This way, "Hinzufügen" / "Bearbeiten" / "Löschen" in the UI propagates to
/// the Finder integrations without requiring a manual re-install.
enum AutoSync {

    static func runIfNeeded() {
        if hasQuickActions() {
            _ = QuickActionInstaller.installAll()
        }
        // The toolbar picker reads connections from disk live, so we do NOT
        // regenerate it on every connection edit — that would needlessly
        // reissue the bundle and break the Finder-toolbar bookmark entry.
    }

    static func hasQuickActions() -> Bool {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Services", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        return entries.contains { $0.lastPathComponent.hasPrefix("Claude · ") && $0.pathExtension == "workflow" }
    }

    static func hasToolbarApps() -> Bool {
        let dir = ToolbarAppInstaller.installDir
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        return entries.contains {
            $0.pathExtension == "app" &&
            ($0.lastPathComponent.hasPrefix("Claude · ") || $0.lastPathComponent == "Claude ▾.app")
        }
    }
}
