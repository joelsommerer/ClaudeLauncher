import Foundation
import Network

/// Lifecycle for the local proxy daemon.
/// The daemon is `ClaudeLauncher --proxy`, spawned as a detached background process.
final class ProxyManager {
    static let shared = ProxyManager()

    private static var pidFile: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeLauncher", isDirectory: true)
            .appendingPathComponent("proxy.pid")
    }

    private static var logFile: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeLauncher", isDirectory: true)
            .appendingPathComponent("proxy.log")
    }

    var port: Int { ConnectionStore.shared.proxyPort }

    /// Starts the proxy daemon if not already reachable. Synchronous best-effort.
    func ensureRunning() {
        if isReachable() { return }
        spawnDaemon()
        // Block briefly until the proxy answers, up to ~2 seconds.
        for _ in 0..<20 {
            if isReachable() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func isReachable() -> Bool {
        let host = "127.0.0.1"
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        let conn = NWConnection(to: endpoint, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ok = true; sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        let result = sem.wait(timeout: .now() + 0.4)
        conn.cancel()
        return result == .success && ok
    }

    private func spawnDaemon() {
        let bundlePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let task = Process()
        task.launchPath = bundlePath
        task.arguments = ["--proxy"]
        // Detach via redirected I/O.
        let logURL = Self.logFile
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            task.standardOutput = handle
            task.standardError = handle
        }
        task.standardInput = FileHandle.nullDevice

        do { try task.run() } catch {
            NSLog("Proxy daemon spawn failed: \(error)")
            return
        }
        // Persist PID.
        let pid = task.processIdentifier
        try? "\(pid)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
    }

    func stop() {
        guard let pidStr = try? String(contentsOf: Self.pidFile),
              let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: Self.pidFile)
    }
}
