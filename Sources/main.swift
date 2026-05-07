import Foundation
import AppKit

// MARK: - CLI argument parsing

let args = CommandLine.arguments

func runCLI() -> Bool {
    guard args.count > 1 else { return false }
    let cmd = args[1]

    if cmd == "--launch" {
        guard args.count >= 3 else {
            fputs("usage: --launch <path> [--backend <uuid>]\n", stderr)
            exit(2)
        }
        let path = args[2]
        var backendId: UUID? = nil
        if args.count >= 5, args[3] == "--backend" {
            backendId = UUID(uuidString: args[4])
        }
        let store = ConnectionStore.shared
        let connection = backendId.flatMap { store.connection(id: $0) } ?? store.defaultConnection
        guard let conn = connection else {
            fputs("no connection configured — open Claude Launcher first\n", stderr)
            exit(1)
        }
        TerminalLauncher.launch(path: path, connection: conn)
        Thread.sleep(forTimeInterval: 0.3)
        exit(0)
    }

    if cmd == "--launch-here" {
        // Same as --launch but resolve the path from Finder ourselves.
        // Used by Toolbar wrapper apps which don't carry a path argument.
        var backendId: UUID? = nil
        if args.count >= 4, args[2] == "--backend" {
            backendId = UUID(uuidString: args[3])
        }
        let store = ConnectionStore.shared
        let connection = backendId.flatMap { store.connection(id: $0) } ?? store.defaultConnection
        guard let conn = connection else {
            fputs("no connection configured — open Claude Launcher first\n", stderr)
            exit(1)
        }
        let path = FinderService.currentPath()
        TerminalLauncher.launch(path: path, connection: conn)
        Thread.sleep(forTimeInterval: 0.3)
        exit(0)
    }

    if cmd == "--install-toolbar-apps" {
        print(ToolbarAppInstaller.installAll())
        exit(0)
    }

    if cmd == "--uninstall-toolbar-apps" {
        ToolbarAppInstaller.uninstallAll()
        print("Toolbar-Apps entfernt")
        exit(0)
    }

    if cmd == "--install-finder-toolbar" {
        print(ToolbarAppInstaller.installAll())
        print(FinderToolbarManager.install())
        exit(0)
    }

    if cmd == "--uninstall-finder-toolbar" {
        print(FinderToolbarManager.uninstall())
        ToolbarAppInstaller.uninstallAll()
        exit(0)
    }

    if cmd == "--picker" {
        PickerController.run()
    }

    if cmd == "--proxy" {
        do {
            let port = ConnectionStore.shared.proxyPort
            try ProxyServer.shared.start(port: port)
            RunLoop.main.run()
        } catch {
            fputs("proxy start failed: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    if cmd == "--install-quick-actions" {
        print(QuickActionInstaller.installAll())
        exit(0)
    }

    if cmd == "--uninstall-quick-actions" {
        QuickActionInstaller.uninstallAll()
        print("Quick Actions entfernt")
        exit(0)
    }

    if cmd == "--help" || cmd == "-h" {
        print("""
        Claude Launcher

        Modes:
          (no args)                            Open settings UI
          --launch <path> [--backend <uuid>]   Open Terminal at path with the
                                               given (or default) connection
          --proxy                              Run proxy daemon (foreground)
          --install-quick-actions              Generate Finder Quick Actions
          --uninstall-quick-actions            Remove Finder Quick Actions
        """)
        exit(0)
    }

    return false
}

if runCLI() {
    // unreachable — runCLI exits when it handles a command.
} else {
    // GUI mode
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
