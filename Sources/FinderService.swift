import Foundation
import AppKit

enum FinderService {
    /// Returns the path of the front Finder window, or selected folder, or Desktop as fallback.
    static func currentPath() -> String {
        let script = """
        tell application "Finder"
            try
                if (count of windows) > 0 then
                    set winTarget to (target of front window) as alias
                    return POSIX path of winTarget
                end if
            end try
            try
                set sel to selection
                if (count of sel) > 0 then
                    set firstItem to item 1 of sel
                    set itemPath to (firstItem as alias)
                    return POSIX path of itemPath
                end if
            end try
            return POSIX path of (path to desktop folder as alias)
        end tell
        """
        return runAppleScript(script) ?? NSHomeDirectory()
    }

    static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
