import Foundation
import AppKit

/// Generates one tiny `.app` bundle per connection. Each wrapper, when launched,
/// asks Finder for its front-window path and calls the main launcher binary
/// with `--launch-here --backend <uuid>`.
///
/// The user drags these wrappers (⌘+drag) to the Finder toolbar so they get
/// "one-click per backend" toolbar buttons.
enum ToolbarAppInstaller {

    /// Where wrapper apps land. The user's ~/Applications folder is conventional
    /// and shows up in Spotlight + can be dragged to the Finder toolbar.
    static var installDir: URL {
        let dir = FileManager.default
            .urls(for: .applicationDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func installAll() -> String {
        uninstallAll()
        let mainBin = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        do {
            try installPicker(mainBin: mainBin, iconURL: iconURL)
            return "Claude ▾.app erstellt in \(installDir.path)"
        } catch {
            NSLog("Picker app install failed: \(error)")
            return "Fehler beim Erstellen von Claude ▾.app: \(error.localizedDescription)"
        }
    }

    static func uninstallAll() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: installDir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "app" {
            let n = url.lastPathComponent
            if n.hasPrefix("Claude · ") || n == "Claude ▾.app" || n == "Claude.app" {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Reveal the install folder in Finder so the user can drag from there into
    /// the Finder toolbar.
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([installDir])
    }

    private static func installPicker(mainBin: String, iconURL: URL?) throws {
        let appName = "Claude ▾.app"
        let bundleId = "ch.joelsommerer.ClaudeLauncher.toolbar.picker"
        let displayName = "Claude ▾"
        let script = """
        #!/bin/sh
        exec "\(mainBin)" --picker
        """
        try writeWrapper(name: appName, displayName: displayName, bundleId: bundleId, script: script, iconURL: iconURL)
    }

    private static func writeWrapper(name: String, displayName: String, bundleId: String, script: String, iconURL: URL?) throws {
        let appURL = installDir.appendingPathComponent(name, isDirectory: true)
        let macosDir = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resDir = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": bundleId,
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "LSUIElement": true,
            "LSMinimumSystemVersion": "14.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        if let iconURL = iconURL {
            try? FileManager.default.copyItem(at: iconURL, to: resDir.appendingPathComponent("AppIcon.icns"))
        }

        let execURL = macosDir.appendingPathComponent("launch")
        try script.write(to: execURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: execURL.path
        )
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: appURL.path
        )
    }

}
