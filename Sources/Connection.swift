import Foundation

enum BackendType: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case ollama
    case lmstudio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic API"
        case .ollama:    return "Ollama"
        case .lmstudio:  return "LM Studio"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .ollama:    return "http://localhost:11434"
        case .lmstudio:  return "http://localhost:1234"
        }
    }

    var isLocal: Bool { self != .anthropic }
}

struct Connection: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var type: BackendType
    var endpoint: String
    var model: String          // empty for anthropic (uses Claude default)
    var apiKey: String?        // anthropic only

    static func defaultAnthropic() -> Connection {
        Connection(
            name: "Anthropic API",
            type: .anthropic,
            endpoint: BackendType.anthropic.defaultEndpoint,
            model: "",
            apiKey: nil
        )
    }
}
