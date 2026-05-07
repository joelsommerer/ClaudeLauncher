import Foundation
import AppKit

/// Adds / removes `Claude ▾.app` to/from the Finder browser toolbar by editing
/// `com.apple.finder`'s `NSToolbar Configuration Browser` preference. Apple
/// does not document this format, but it is stable across recent macOS
/// releases and matches what dragging an app into the toolbar produces.
///
/// This requires Finder to be relaunched to pick up the change.
enum FinderToolbarManager {

    private static let prefsBundleID = "com.apple.finder" as CFString
    private static let toolbarKey = "NSToolbar Configuration Browser" as CFString
    private static var prefsFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/com.apple.finder.plist")
    }

    private static var pickerAppURL: URL {
        ToolbarAppInstaller.installDir.appendingPathComponent("Claude ▾.app")
    }

    /// Adds the picker to the Finder toolbar (idempotent: silently no-op if
    /// already present). Returns a human-readable status.
    @discardableResult
    static func install() -> String {
        let app = pickerAppURL
        guard FileManager.default.fileExists(atPath: app.path) else {
            return "Claude ▾.app fehlt — erst Picker generieren"
        }

        // Kill Finder FIRST so it doesn't write its in-memory (stale) prefs
        // back over our changes when it next saves. launchd will respawn it
        // automatically once we're done.
        killFinder()

        guard var config = readToolbarConfig() else {
            return "Konnte Finder-Toolbar-Config nicht lesen"
        }

        var identifiers = (config["TB Item Identifiers"] as? [Any]) ?? []
        var plists = (config["TB Item Plists"] as? [String: Any]) ?? [:]

        // Strip orphan plists entries (keys present in plists but NOT
        // referenced by identifiers). Finder dedupes its toolbar based on the
        // resolved file path of bookmark data, so an orphan whose bookmark
        // still resolves to our Claude ▾.app would clobber our newly-added
        // identifier on the next Finder restart. Cleaning these out first
        // prevents the dedupe collision.
        let identifierStrings = identifiers.compactMap { $0 as? String }
        for k in plists.keys where !identifierStrings.contains(k) {
            plists.removeValue(forKey: k)
        }

        // After cleaning, allocate the next free integer key.
        let appPath = app.path
        var existingKey: String? = nil
        for (k, v) in plists {
            guard let dict = v as? [String: Any],
                  let urlStr = dict["_CFURLString"] as? String else { continue }
            if urlStr.contains("Claude%20%E2%96%BE.app") || urlStr.contains("/Claude ▾.app/") {
                existingKey = k
                break
            }
        }

        let key: String
        if let k = existingKey {
            key = k
        } else {
            var nextID = 1
            while plists["\(nextID)"] != nil { nextID += 1 }
            key = "\(nextID)"
        }

        // Use Foundation's URL encoder so spaces/▾ become %20/%E2%96%BE.
        // Finder strips entries with malformed URLs at next launch, which is
        // why a hand-built "file://…" string with raw special characters
        // disappears as soon as Finder restarts.
        let encodedURLString = URL(fileURLWithPath: appPath, isDirectory: true).absoluteString
        var entry: [String: Any] = [
            "_CFURLString": encodedURLString,
            "_CFURLStringType": 15
        ]
        // No options → standard inline bookmark data, which is what Finder
        // expects under "_CFURLAliasData". `.suitableForBookmarkFile` makes
        // bytes for a user-visible .alias file and Finder treats those as
        // invalid here.
        if let bookmark = try? app.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            entry["_CFURLAliasData"] = bookmark
        }
        plists[key] = entry

        // Ensure the identifier is in the identifier array. Insert before
        // the search field if present, else append.
        let alreadyInIdentifiers = identifiers.contains { ($0 as? String) == key }
        if !alreadyInIdentifiers {
            if let searchIdx = identifiers.firstIndex(where: { ($0 as? String) == "com.apple.finder.SRCH" }) {
                identifiers.insert(key, at: searchIdx)
            } else {
                identifiers.append(key)
            }
        }

        config["TB Item Identifiers"] = identifiers
        config["TB Item Plists"] = plists

        guard writeToolbarConfig(config) else {
            return "Konnte Finder-Toolbar-Config nicht schreiben"
        }
        // Nudge Finder to relaunch and pick up the new prefs.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        }
        return "Claude ▾ zur Finder-Toolbar hinzugefügt"
    }

    /// Removes the picker from the Finder toolbar. Idempotent.
    @discardableResult
    static func uninstall() -> String {
        killFinder()
        guard var config = readToolbarConfig() else {
            return "Konnte Finder-Toolbar-Config nicht lesen"
        }
        var identifiers = (config["TB Item Identifiers"] as? [Any]) ?? []
        var plists = (config["TB Item Plists"] as? [String: Any]) ?? [:]

        // Drop any entry whose URL string mentions Claude ▾.app — covers both
        // raw file:// URLs and macOS-encoded variants (Claude%20%E2%96%BE.app).
        var droppedKey: String? = nil
        for (k, v) in plists {
            guard let dict = v as? [String: Any],
                  let urlStr = dict["_CFURLString"] as? String else { continue }
            if urlStr.contains("Claude%20%E2%96%BE.app") || urlStr.contains("/Claude ▾.app/") {
                droppedKey = k
                break
            }
        }
        guard let key = droppedKey else {
            return "Nicht in der Toolbar (oder bereits entfernt)"
        }
        plists.removeValue(forKey: key)
        identifiers.removeAll { ($0 as? String) == key }
        config["TB Item Identifiers"] = identifiers
        config["TB Item Plists"] = plists

        guard writeToolbarConfig(config) else {
            return "Konnte Finder-Toolbar-Config nicht schreiben"
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        }
        return "Claude ▾ aus Finder-Toolbar entfernt"
    }

    // MARK: - Internals

    /// Reads the entire `com.apple.finder.plist` from disk so we operate on
    /// a snapshot that's independent of cfprefsd's cache. Returns the full
    /// preferences dict (we patch the toolbar config inside it).
    private static func readPrefsFile() -> [String: Any]? {
        guard let data = try? Data(contentsOf: prefsFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    private static func readToolbarConfig() -> [String: Any]? {
        // Read directly from disk so we don't get a stale cfprefsd snapshot.
        guard let plist = readPrefsFile() else { return nil }
        return plist[toolbarKey as String] as? [String: Any]
    }

    /// Writes the toolbar config by patching the on-disk plist file directly.
    /// We call this while Finder is dead, so cfprefsd has no in-memory copy
    /// to overwrite us with on next launch.
    private static func writeToolbarConfig(_ config: [String: Any]) -> Bool {
        guard var plist = readPrefsFile() else { return false }
        plist[toolbarKey as String] = config
        do {
            let newData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            try newData.write(to: prefsFileURL, options: .atomic)
            // Tell cfprefsd to forget its cache for this domain, so the next
            // process that asks for com.apple.finder prefs reads our new file.
            killCfprefsd()
            return true
        } catch {
            NSLog("[ToolbarMgr] write failed: \(error)")
            return false
        }
    }

    private static func killCfprefsd() {
        // -HUP forces cfprefsd to reload. SIGTERM is overkill here.
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["-HUP", "cfprefsd"]
        try? task.run()
        task.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)
    }

    private static func killFinder() {
        // SIGTERM gives Finder a chance to save state, but it then writes its
        // in-memory copy of prefs back, possibly overwriting our edit. SIGKILL
        // skips that, ensuring our prefs survive.
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["-9", "Finder"]
        try? task.run()
        task.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
    }
}
