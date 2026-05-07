import Foundation
import Combine

final class ConnectionStore: ObservableObject {
    static let shared = ConnectionStore()

    @Published var connections: [Connection] = []
    @Published var defaultId: UUID?
    @Published var proxyPort: Int = 8765

    private struct Config: Codable {
        var connections: [Connection]
        var defaultId: UUID?
        var proxyPort: Int = 8765
    }

    private static let configDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var configURL: URL { configDir.appendingPathComponent("config.json") }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            let anthropic = Connection.defaultAnthropic()
            connections = [anthropic]
            defaultId = anthropic.id
            save()
            return
        }
        connections = config.connections
        defaultId = config.defaultId ?? config.connections.first?.id
        proxyPort = config.proxyPort
    }

    func save() {
        let config = Config(connections: connections, defaultId: defaultId, proxyPort: proxyPort)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
        // Keep installed Finder integrations in sync with the live connection
        // list. Skipped for the proxy daemon (which calls load(), not save()).
        AutoSync.runIfNeeded()
    }

    var defaultConnection: Connection? {
        if let id = defaultId, let conn = connections.first(where: { $0.id == id }) {
            return conn
        }
        return connections.first
    }

    func connection(id: UUID) -> Connection? {
        connections.first(where: { $0.id == id })
    }

    func add(_ connection: Connection) {
        connections.append(connection)
        if defaultId == nil { defaultId = connection.id }
        save()
    }

    func update(_ connection: Connection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
        save()
    }

    func remove(id: UUID) {
        connections.removeAll(where: { $0.id == id })
        if defaultId == id { defaultId = connections.first?.id }
        save()
    }

    func setDefault(id: UUID) {
        defaultId = id
        save()
    }
}
