import Foundation

/// Lists models that can be selected for Ollama / LM Studio.
enum ModelDiscovery {
    static func models(for type: BackendType, endpoint: String) async -> [String] {
        switch type {
        case .ollama:    return await ollamaModels(endpoint: endpoint)
        case .lmstudio:  return await lmStudioModels(endpoint: endpoint)
        case .anthropic: return []
        }
    }

    private static func ollamaModels(endpoint: String) async -> [String] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            let r = try JSONDecoder().decode(Response.self, from: data)
            return r.models.map { $0.name }.sorted()
        } catch {
            return []
        }
    }

    private static func lmStudioModels(endpoint: String) async -> [String] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            let r = try JSONDecoder().decode(Response.self, from: data)
            return r.data.map { $0.id }.sorted()
        } catch {
            return []
        }
    }
}
