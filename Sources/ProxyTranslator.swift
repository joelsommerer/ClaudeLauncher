import Foundation

/// Translates between Anthropic's `/v1/messages` schema and OpenAI's
/// `/v1/chat/completions` schema (which LM Studio speaks).
///
/// Tool-use is translated end-to-end: tool definitions, tool calls in the
/// model's response, and tool results in subsequent user messages all flow
/// through correctly. This is what lets Claude Code's Bash / Read / Edit
/// tools work against a local LLM.
enum ProxyTranslator {

    // MARK: - Anthropic input schema (subset)

    struct AnthropicRequest: Decodable {
        let model: String?
        let max_tokens: Int?
        let messages: [AnthropicMessage]
        let system: AnySystem?
        let stream: Bool?
        let temperature: Double?
        let tools: [AnthropicTool]?
    }

    struct AnthropicTool: Decodable {
        let name: String
        let description: String?
        let input_schema: AnyJSON?
    }

    struct AnthropicMessage: Decodable {
        let role: String
        let content: MessageContent
    }

    /// A message's `content` is either a plain string or an array of typed
    /// blocks (text / tool_use / tool_result).
    enum MessageContent: Decodable {
        case text(String)
        case blocks([ContentBlock])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let blocks = try? c.decode([ContentBlock].self) { self = .blocks(blocks); return }
            self = .text("")
        }
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        // tool_use fields
        let id: String?
        let name: String?
        let input: AnyJSON?
        // tool_result fields
        let tool_use_id: String?
        let content: ToolResultContent?
    }

    /// `tool_result.content` is either a string or an array of blocks (Claude
    /// Code commonly sends a string, but the spec allows arrays of text blocks).
    enum ToolResultContent: Decodable {
        case text(String)
        case blocks([ContentBlock])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let arr = try? c.decode([ContentBlock].self) { self = .blocks(arr); return }
            self = .text("")
        }

        var asText: String {
            switch self {
            case .text(let s): return s
            case .blocks(let arr): return arr.compactMap { $0.text }.joined(separator: "\n")
            }
        }
    }

    enum AnySystem: Decodable {
        case text(String)
        case blocks([SystemBlock])
        case none

        struct SystemBlock: Decodable {
            let type: String
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .none; return }
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let b = try? c.decode([SystemBlock].self) { self = .blocks(b); return }
            self = .none
        }

        var asText: String {
            switch self {
            case .text(let s): return s
            case .blocks(let b): return b.compactMap { $0.text }.joined(separator: "\n")
            case .none: return ""
            }
        }
    }

    /// Wrapper that decodes any JSON value (object, array, primitive) and lets
    /// us re-serialize it later. Lets us pass through tool input_schemas and
    /// tool inputs without losing detail.
    struct AnyJSON: Decodable {
        let raw: Any

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { raw = NSNull(); return }
            if let v = try? c.decode(Bool.self)   { raw = v; return }
            if let v = try? c.decode(Int.self)    { raw = v; return }
            if let v = try? c.decode(Double.self) { raw = v; return }
            if let v = try? c.decode(String.self) { raw = v; return }
            if let v = try? c.decode([AnyJSON].self) { raw = v.map(\.raw); return }
            if let v = try? c.decode([String: AnyJSON].self) {
                raw = v.mapValues(\.raw); return
            }
            raw = NSNull()
        }

        static func wrap(_ value: Any) -> Any { value }
    }

    // MARK: - OpenAI request building

    /// Convert an Anthropic request body into an OpenAI `/v1/chat/completions`
    /// body for LM Studio. Returns a JSON-serializable dict.
    static func openAIRequestBody(
        from req: AnthropicRequest,
        model: String,
        stream: Bool
    ) -> [String: Any] {
        var messages: [[String: Any]] = []

        let sys = req.system?.asText ?? ""
        if !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }

        for m in req.messages {
            switch m.content {
            case .text(let s):
                messages.append(["role": m.role, "content": s])

            case .blocks(let blocks):
                if m.role == "assistant" {
                    messages.append(assistantMessage(from: blocks))
                } else { // user
                    messages.append(contentsOf: userMessages(from: blocks))
                }
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "max_tokens": req.max_tokens ?? 4096,
            "temperature": req.temperature ?? 0.7
        ]

        if let tools = req.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                var function: [String: Any] = ["name": tool.name]
                if let d = tool.description { function["description"] = d }
                if let s = tool.input_schema?.raw { function["parameters"] = s }
                return ["type": "function", "function": function]
            }
            body["tool_choice"] = "auto"
        }

        return body
    }

    /// Build the assistant message dict from a list of Anthropic content blocks.
    /// Combines text blocks into `content` and tool_use blocks into `tool_calls`.
    private static func assistantMessage(from blocks: [ContentBlock]) -> [String: Any] {
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []
        for b in blocks {
            switch b.type {
            case "text":
                if let t = b.text { textParts.append(t) }
            case "tool_use":
                guard let id = b.id, let name = b.name else { continue }
                let argsJSON: String
                if let raw = b.input?.raw,
                   let data = try? JSONSerialization.data(withJSONObject: raw, options: []),
                   let s = String(data: data, encoding: .utf8) {
                    argsJSON = s
                } else {
                    argsJSON = "{}"
                }
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": argsJSON]
                ])
            default:
                break
            }
        }
        var msg: [String: Any] = ["role": "assistant"]
        let combined = textParts.joined(separator: "\n")
        msg["content"] = combined.isEmpty ? NSNull() : combined
        if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
        return msg
    }

    /// Build the (possibly multiple) user-side messages from a list of blocks.
    /// Each tool_result block becomes its own `role: "tool"` message; remaining
    /// text blocks become a normal `role: "user"` message at the end.
    private static func userMessages(from blocks: [ContentBlock]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var textParts: [String] = []
        for b in blocks {
            switch b.type {
            case "text":
                if let t = b.text { textParts.append(t) }
            case "tool_result":
                guard let useId = b.tool_use_id else { continue }
                out.append([
                    "role": "tool",
                    "tool_call_id": useId,
                    "content": b.content?.asText ?? ""
                ])
            default:
                break
            }
        }
        let combined = textParts.joined(separator: "\n")
        if !combined.isEmpty {
            out.append(["role": "user", "content": combined])
        }
        return out
    }

    // MARK: - Anthropic SSE encoders

    static func sseEvent(_ event: String, _ payload: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
        let jsonStr = String(data: json, encoding: .utf8) ?? "{}"
        return Data("event: \(event)\ndata: \(jsonStr)\n\n".utf8)
    }

    static func makeMessageId() -> String {
        "msg_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
    }

    static func makeToolUseId() -> String {
        "toolu_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
    }

    static func messageStartEvent(model: String, messageId: String) -> Data {
        sseEvent("message_start", [
            "type": "message_start",
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": model,
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0]
            ]
        ])
    }

    static func textBlockStart(index: Int) -> Data {
        sseEvent("content_block_start", [
            "type": "content_block_start",
            "index": index,
            "content_block": ["type": "text", "text": ""]
        ])
    }

    static func textBlockDelta(index: Int, text: String) -> Data {
        sseEvent("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "text_delta", "text": text]
        ])
    }

    static func toolUseBlockStart(index: Int, id: String, name: String) -> Data {
        sseEvent("content_block_start", [
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": [:] as [String: Any]
            ]
        ])
    }

    static func toolUseBlockDelta(index: Int, partialJSON: String) -> Data {
        sseEvent("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": ["type": "input_json_delta", "partial_json": partialJSON]
        ])
    }

    static func blockStop(index: Int) -> Data {
        sseEvent("content_block_stop", [
            "type": "content_block_stop",
            "index": index
        ])
    }

    static func messageDeltaEvent(stopReason: String, outputTokens: Int) -> Data {
        sseEvent("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
            "usage": ["output_tokens": outputTokens]
        ])
    }

    static func messageStopEvent() -> Data {
        sseEvent("message_stop", ["type": "message_stop"])
    }

    // MARK: - Non-streaming response builder

    /// Build the Anthropic `/v1/messages` response body from an OpenAI
    /// `/v1/chat/completions` JSON object.
    static func nonStreamingResponse(model: String, openAI: [String: Any]) -> [String: Any] {
        var contentBlocks: [[String: Any]] = []
        var stopReason = "end_turn"

        if let choices = openAI["choices"] as? [[String: Any]],
           let first = choices.first {
            if let msg = first["message"] as? [String: Any] {
                if let text = msg["content"] as? String, !text.isEmpty {
                    contentBlocks.append(["type": "text", "text": text])
                }
                if let calls = msg["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let rawId = (call["id"] as? String) ?? UUID().uuidString
                        let id = rawId.hasPrefix("toolu_") ? rawId : "toolu_\(rawId)"
                        let function = call["function"] as? [String: Any] ?? [:]
                        let name = (function["name"] as? String) ?? "unknown"
                        let argsStr = (function["arguments"] as? String) ?? "{}"
                        let inputObj: Any = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) ?? [:]
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": inputObj
                        ])
                    }
                    stopReason = "tool_use"
                }
            }
            if let reason = first["finish_reason"] as? String {
                switch reason {
                case "length":     stopReason = "max_tokens"
                case "tool_calls": stopReason = "tool_use"
                default:           break
                }
            }
        }

        if contentBlocks.isEmpty {
            contentBlocks = [["type": "text", "text": ""]]
        }

        let usage = openAI["usage"] as? [String: Any] ?? [:]
        return [
            "id": makeMessageId(),
            "type": "message",
            "role": "assistant",
            "content": contentBlocks,
            "model": model,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": usage["prompt_tokens"] as? Int ?? 0,
                "output_tokens": usage["completion_tokens"] as? Int ?? 0
            ]
        ]
    }
}
