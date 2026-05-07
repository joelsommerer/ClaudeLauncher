import Foundation
import AppKit

enum TerminalLauncher {
    /// Open Terminal.app at `path` and start `claude` configured for `connection`.
    static func launch(path: String, connection: Connection) {
        // Ensure proxy is running (or starting) before we hand off to Terminal.
        if connection.type.isLocal {
            ProxyManager.shared.ensureRunning()
        }

        let claudeBin = ClaudeFinder.locate() ?? "claude"
        let envExports = environmentExports(for: connection)
        let escapedPath = shellEscape(path)
        let escapedClaude = shellEscape(claudeBin)

        // For local backends we MUST pass --bare. Otherwise Claude Code uses the
        // OAuth login (Pro/Max) and silently ignores ANTHROPIC_BASE_URL / KEY,
        // bypassing our proxy entirely.
        let claudeArgs = connection.type.isLocal ? " --bare" : ""

        let banner = bannerCommand(for: connection)
        let titleSet = titleEscape(for: connection)

        let cmd = """
        \(envExports)cd \(escapedPath); \(titleSet)\(banner) exec \(escapedClaude)\(claudeArgs)
        """

        runInTerminal(cmd)
    }

    /// echo command that prints a one-line banner so the user immediately sees
    /// which connection / model is active in this Terminal session.
    private static func bannerCommand(for connection: Connection) -> String {
        // ANSI: cyan bold for the prefix, default for the rest.
        let label: String
        switch connection.type {
        case .anthropic:
            label = "Anthropic API\\033[0m  (api.anthropic.com)"
        case .ollama:
            let model = connection.model.isEmpty ? "default" : connection.model
            label = "Ollama\\033[0m  \(model)  via proxy :\(ConnectionStore.shared.proxyPort) → \(connection.endpoint)"
        case .lmstudio:
            let model = connection.model.isEmpty ? "default" : connection.model
            label = "LM Studio\\033[0m  \(model)  via proxy :\(ConnectionStore.shared.proxyPort) → \(connection.endpoint)"
        }
        let line = "  ⌁ \(connection.name) — \(label)"
        // printf so escape sequences render. A blank line above for separation.
        return "printf '\\n\\033[36;1m%s\\033[0m\\n\\n' '\(line.replacingOccurrences(of: "'", with: "'\\''"))';"
    }

    /// Set the Terminal window/tab title via the OSC 0 escape, so it shows the
    /// connection name instead of just "claude".
    private static func titleEscape(for connection: Connection) -> String {
        let title = "Claude · \(connection.name)"
            .replacingOccurrences(of: "'", with: "'\\''")
        return "printf '\\033]0;%s\\007' '\(title)';"
    }

    private static func environmentExports(for connection: Connection) -> String {
        var lines: [String] = []
        switch connection.type {
        case .anthropic:
            if let key = connection.apiKey, !key.isEmpty {
                lines.append("export ANTHROPIC_API_KEY=\(shellEscape(key))")
            }
            // Reset BASE_URL in case a previous proxy session set it in shell rc.
            lines.append("unset ANTHROPIC_BASE_URL")
        case .ollama, .lmstudio:
            let port = ConnectionStore.shared.proxyPort
            lines.append("export ANTHROPIC_BASE_URL=http://localhost:\(port)")
            // The API key IS the connection UUID. Claude Code forwards it as
            // the `x-api-key` header and our proxy uses it to look up which
            // local backend (Ollama/LM Studio + which model) to route to.
            lines.append("export ANTHROPIC_API_KEY=\(connection.id.uuidString)")
            if !connection.model.isEmpty {
                lines.append("export ANTHROPIC_MODEL=\(shellEscape(connection.model))")
            }
        }
        if lines.isEmpty { return "" }
        return lines.joined(separator: "; ") + "; "
    }

    private static func runInTerminal(_ command: String) {
        // Prefer Terminal.app via AppleScript. Open new window if Terminal already running.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            NSLog("Terminal launch error: \(err)")
        }
    }

    private static func shellEscape(_ s: String) -> String {
        // Single-quote quoting; close, escape inner ', reopen.
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
