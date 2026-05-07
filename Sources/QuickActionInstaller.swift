import Foundation
import AppKit

/// Generates Automator Quick Action (.workflow) bundles in ~/Library/Services,
/// one per configured connection. Right-click on a folder in Finder → Quick Actions
/// will then show "Claude · <Connection Name>".
enum QuickActionInstaller {

    /// Folder where macOS reads user services / quick actions from.
    private static var servicesDir: URL {
        let url = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Services", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// File-name prefix used for our quick actions (so we can find/uninstall them).
    private static let prefix = "Claude · "

    @discardableResult
    static func installAll() -> String {
        // Remove existing first so renamed/deleted connections don't linger.
        uninstallAll()
        let store = ConnectionStore.shared
        let appPath = Bundle.main.bundlePath
        let executable = Bundle.main.executablePath ?? (appPath + "/Contents/MacOS/ClaudeLauncher")
        var installed = 0
        for conn in store.connections {
            do {
                try installOne(connection: conn, executablePath: executable)
                installed += 1
            } catch {
                NSLog("Quick Action install failed for \(conn.name): \(error)")
            }
        }
        // Notify pbs so the Services menu picks up changes immediately.
        let task = Process()
        task.launchPath = "/System/Library/CoreServices/pbs"
        task.arguments = ["-flush"]
        try? task.run()
        task.waitUntilExit()
        return "\(installed) Quick Actions installiert"
    }

    static func uninstallAll() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: servicesDir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "workflow" {
            try? fm.removeItem(at: url)
        }
    }

    private static func installOne(connection: Connection, executablePath: String) throws {
        let safeName = connection.name.replacingOccurrences(of: "/", with: "-")
        let bundleURL = servicesDir.appendingPathComponent("\(prefix)\(safeName).workflow", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        // Write Info.plist (declares the Service).
        let infoPlist = serviceInfoPlist(connectionName: safeName)
        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))

        // Write document.wflow (the workflow with a Run-Shell-Script action).
        let cmd = shellCommand(executable: executablePath, backendId: connection.id.uuidString)
        let wflow = workflowPlist(command: cmd)
        let wflowData = try PropertyListSerialization.data(fromPropertyList: wflow, format: .xml, options: 0)
        try wflowData.write(to: contents.appendingPathComponent("document.wflow"))
    }

    private static func shellCommand(executable: String, backendId: String) -> String {
        // Automator passes folder paths as arguments when inputMethod=1.
        // We launch our binary for the first selected folder.
        return """
        for f in "$@"; do
            "\(executable)" --launch "$f" --backend \(backendId)
            break
        done
        """
    }

    private static func serviceInfoPlist(connectionName: String) -> [String: Any] {
        return [
            "NSServices": [[
                "NSMenuItem": ["default": "Claude · \(connectionName)"],
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": [
                    "NSApplicationIdentifier": "com.apple.finder"
                ],
                "NSSendFileTypes": [
                    "public.folder",
                    "public.directory"
                ]
            ]]
        ]
    }

    private static func workflowPlist(command: String) -> [String: Any] {
        let actionUUID = UUID().uuidString
        let inputUUID = UUID().uuidString
        let outputUUID = UUID().uuidString

        let action: [String: Any] = [
            "action": [
                "AMAccepts": [
                    "Container": "List",
                    "Optional": true,
                    "Types": ["com.apple.cocoa.path"]
                ],
                "AMActionVersion": "2.0.3",
                "AMApplication": ["Automator"],
                "AMParameterProperties": [
                    "COMMAND_STRING": [:],
                    "CheckedForUserDefaultShell": [:],
                    "inputMethod": [:],
                    "shell": [:],
                    "source": [:]
                ],
                "AMProvides": [
                    "Container": "List",
                    "Types": ["com.apple.cocoa.string"]
                ],
                "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                "ActionName": "Run Shell Script",
                "ActionParameters": [
                    "COMMAND_STRING": command,
                    "CheckedForUserDefaultShell": true,
                    "inputMethod": 1,            // pass input as args
                    "shell": "/bin/zsh",
                    "source": ""
                ] as [String: Any],
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.3",
                "CanShowSelectedItemsWhenRun": false,
                "CanShowWhenRun": true,
                "Category": ["AMCategoryUtilities"],
                "Class Name": "RunShellScriptAction",
                "InputUUID": inputUUID,
                "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
                "OutputUUID": outputUUID,
                "UUID": actionUUID,
                "UnlocalizedApplications": ["Automator"],
                "arguments": [
                    "0": ["default value": 0, "name": "inputMethod", "required": "0", "type": "0", "uuid": "0"],
                    "1": ["default value": false, "name": "CheckedForUserDefaultShell", "required": "0", "type": "0", "uuid": "1"],
                    "2": ["default value": "", "name": "source", "required": "0", "type": "0", "uuid": "2"],
                    "3": ["default value": "", "name": "COMMAND_STRING", "required": "0", "type": "0", "uuid": "3"],
                    "4": ["default value": "/bin/sh", "name": "shell", "required": "0", "type": "0", "uuid": "4"]
                ],
                "isViewVisible": 1,
                "location": "309.500000:316.000000",
                "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib"
            ] as [String: Any],
            "isViewVisible": 1
        ]

        return [
            "AMApplicationBuild": "492",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [action],
            "connectors": [:],
            "workflowMetaData": [
                "serviceApplicationBundleID": "com.apple.finder",
                "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject.folder",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": 0,
                "useAutomaticInputType": 0,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu"
            ] as [String: Any]
        ]
    }
}
