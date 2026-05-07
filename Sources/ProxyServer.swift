import Foundation
import Network

/// Local HTTP/1.1 server listening on 127.0.0.1:<port>.
/// Accepts Anthropic-format requests and forwards them to the chosen local backend.
final class ProxyServer {
    static let shared = ProxyServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "proxy.server", qos: .userInitiated)
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private let sessionsLock = NSLock()

    func registerSession(_ s: ProxySession) {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        sessions[ObjectIdentifier(s)] = s
    }

    func unregisterSession(_ s: ProxySession) {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        sessions.removeValue(forKey: ObjectIdentifier(s))
    }

    func start(port: Int) throws {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "ProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        let l = try NWListener(using: params, on: p)
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.stateUpdateHandler = { state in
            NSLog("[Proxy] listener state: \(state)")
        }
        l.start(queue: queue)
        listener = l
        NSLog("[Proxy] listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        let session = ProxySession(connection: conn, queue: queue)
        registerSession(session)
        session.start()
    }
}

/// Per-connection HTTP session.
final class ProxySession {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let parser = HTTPRequestParser()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.conn = connection
        self.queue = queue
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.conn.cancel() }
            if case .cancelled = state { /* gone */ }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data = data, !data.isEmpty {
                self.parser.append(data)
                if let req = self.parser.parse() {
                    self.handle(req)
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func handle(_ req: HTTPRequest) {
        switch (req.method, req.path) {
        case ("GET", "/health"):
            send(HTTPResponse.json(["ok": true]))
        case ("GET", "/v1/models"):
            send(HTTPResponse.json(["data": [], "object": "list"]))
        case ("POST", "/v1/messages"):
            handleMessages(req)
        case ("POST", _) where req.path.hasPrefix("/v1/messages"):
            handleMessages(req)
        default:
            send(HTTPResponse.make(status: 404, statusText: "Not Found",
                                   headers: [("Content-Type", "text/plain")],
                                   body: Data("not found\n".utf8)))
        }
    }

    private func handleMessages(_ req: HTTPRequest) {
        let store = ConnectionStore.shared
        store.load()
        var connection: Connection?
        if let key = req.header("x-api-key"),
           let uuid = UUID(uuidString: key),
           let c = store.connection(id: uuid) {
            connection = c
        }
        if connection == nil { connection = store.defaultConnection }
        guard let target = connection else {
            send(HTTPResponse.json(["error": ["type": "invalid_request_error", "message": "no backend configured"]], status: 400))
            return
        }
        if target.type == .anthropic {
            send(HTTPResponse.json(["error": ["type": "invalid_request_error", "message": "anthropic backend selected but proxy received the request"]], status: 400))
            return
        }
        guard let anthropicReq = try? JSONDecoder().decode(ProxyTranslator.AnthropicRequest.self, from: req.body) else {
            send(HTTPResponse.json(["error": ["type": "invalid_request_error", "message": "could not parse Anthropic request"]], status: 400))
            return
        }

        let stream = anthropicReq.stream ?? false
        let model = !target.model.isEmpty ? target.model : (anthropicReq.model ?? "")

        switch target.type {
        case .ollama:
            forwardToOllama(target: target, req: anthropicReq, model: model, stream: stream)
        case .lmstudio:
            forwardToLMStudio(target: target, req: anthropicReq, model: model, stream: stream)
        case .anthropic:
            break
        }
    }

    // MARK: - LM Studio (full OpenAI-compatible, with tool support)

    private func forwardToLMStudio(target: Connection,
                                   req: ProxyTranslator.AnthropicRequest,
                                   model: String,
                                   stream: Bool) {
        let endpoint = target.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/chat/completions"
        guard let url = URL(string: endpoint) else { sendError("invalid endpoint"); return }
        let body = ProxyTranslator.openAIRequestBody(from: req, model: model, stream: stream)

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        if stream {
            streamFromOpenAI(urlReq: urlReq, model: model)
        } else {
            nonStreamFromOpenAI(urlReq: urlReq, model: model)
        }
    }

    // MARK: - Ollama (text-only path; tool support varies by model)

    private func forwardToOllama(target: Connection,
                                 req: ProxyTranslator.AnthropicRequest,
                                 model: String,
                                 stream: Bool) {
        let endpoint = target.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat"
        guard let url = URL(string: endpoint) else { sendError("invalid endpoint"); return }
        // Build the same OpenAI-style body, then translate to Ollama's slightly
        // different shape (it accepts `tools` and OpenAI-style messages on
        // current versions, but uses `options.num_predict` instead of `max_tokens`).
        var body = ProxyTranslator.openAIRequestBody(from: req, model: model, stream: stream)
        if let max = body.removeValue(forKey: "max_tokens") {
            body["options"] = ["num_predict": max, "temperature": body["temperature"] ?? 0.7]
        }
        body.removeValue(forKey: "temperature")

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        if stream {
            streamFromOllama(urlReq: urlReq, model: model)
        } else {
            nonStreamFromOllama(urlReq: urlReq, model: model)
        }
    }

    // MARK: - Non-streaming response handlers

    private func nonStreamFromOpenAI(urlReq: URLRequest, model: String) {
        URLSession.shared.dataTask(with: urlReq) { [weak self] data, _, error in
            guard let self else { return }
            if let error = error { self.sendError(error.localizedDescription); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.sendError("invalid upstream response"); return
            }
            let resp = ProxyTranslator.nonStreamingResponse(model: model, openAI: obj)
            self.send(HTTPResponse.json(resp))
        }.resume()
    }

    private func nonStreamFromOllama(urlReq: URLRequest, model: String) {
        // Ollama returns OpenAI-style `message` directly; wrap it into
        // OpenAI-compatible shape so our translator can handle it uniformly.
        URLSession.shared.dataTask(with: urlReq) { [weak self] data, _, error in
            guard let self else { return }
            if let error = error { self.sendError(error.localizedDescription); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.sendError("invalid upstream response"); return
            }
            var openAILike: [String: Any] = [:]
            var finishReason = "stop"
            if let reason = obj["done_reason"] as? String, reason == "length" {
                finishReason = "length"
            }
            let msg = (obj["message"] as? [String: Any]) ?? [:]
            openAILike["choices"] = [[
                "message": msg,
                "finish_reason": finishReason
            ]]
            let resp = ProxyTranslator.nonStreamingResponse(model: model, openAI: openAILike)
            self.send(HTTPResponse.json(resp))
        }.resume()
    }

    // MARK: - Streaming response handlers

    private func streamFromOpenAI(urlReq: URLRequest, model: String) {
        let messageId = ProxyTranslator.makeMessageId()
        sendRaw(HTTPResponse.sseHead())
        sendRaw(ProxyTranslator.messageStartEvent(model: model, messageId: messageId))

        let translator = OpenAIStreamTranslator(emit: { [weak self] data in self?.sendRaw(data) },
                                                close: { [weak self] in self?.close() })
        let session = URLSession(configuration: .default, delegate: translator, delegateQueue: nil)
        let task = session.dataTask(with: urlReq)
        translator.task = task
        task.resume()
    }

    private func streamFromOllama(urlReq: URLRequest, model: String) {
        let messageId = ProxyTranslator.makeMessageId()
        sendRaw(HTTPResponse.sseHead())
        sendRaw(ProxyTranslator.messageStartEvent(model: model, messageId: messageId))

        let translator = OllamaStreamTranslator(emit: { [weak self] data in self?.sendRaw(data) },
                                                close: { [weak self] in self?.close() })
        let session = URLSession(configuration: .default, delegate: translator, delegateQueue: nil)
        let task = session.dataTask(with: urlReq)
        translator.task = task
        task.resume()
    }

    // MARK: - Send helpers

    fileprivate func send(_ data: Data) { sendRaw(data); close() }

    fileprivate func sendRaw(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    fileprivate func sendError(_ msg: String, status: Int = 500) {
        send(HTTPResponse.json(["error": ["type": "api_error", "message": msg]], status: status))
    }

    fileprivate func close() {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            self.conn.cancel()
            ProxyServer.shared.unregisterSession(self)
        })
    }
}

// MARK: - OpenAI SSE → Anthropic SSE translator

/// Parses OpenAI's `data: {...}` SSE stream and emits Anthropic-format SSE
/// events (text deltas + tool_use blocks) to the downstream connection.
final class OpenAIStreamTranslator: NSObject, URLSessionDataDelegate {
    var task: URLSessionDataTask?
    private let emit: (Data) -> Void
    private let close: () -> Void
    private var lineBuffer = ""
    private var stopReason = "end_turn"
    private var outputTokens = 0

    /// Whether we have started the (single) text content block yet.
    private var textBlockStarted = false
    /// Has the text block been closed?
    private var textBlockClosed = false
    /// Map from OpenAI tool_call array-index → our Anthropic content block index.
    private var toolBlockIndexByCallIndex: [Int: Int] = [:]
    /// Tracks which tool blocks we've already opened (so we only emit
    /// content_block_start once per call, even when the function name arrives
    /// in a later delta).
    private var openedToolCallIndices: Set<Int> = []
    /// Next available Anthropic content-block index.
    private var nextBlockIndex = 0

    init(emit: @escaping (Data) -> Void, close: @escaping () -> Void) {
        self.emit = emit
        self.close = close
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lineBuffer += s
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Close any still-open blocks (text first, then tool blocks in order).
        if textBlockStarted && !textBlockClosed {
            emit(ProxyTranslator.blockStop(index: 0))
            textBlockClosed = true
        }
        for idx in toolBlockIndexByCallIndex.values.sorted() {
            emit(ProxyTranslator.blockStop(index: idx))
        }
        if let error = error {
            emit(ProxyTranslator.sseEvent("error", ["type": "error", "error": ["type": "api_error", "message": error.localizedDescription]]))
        } else {
            emit(ProxyTranslator.messageDeltaEvent(stopReason: stopReason, outputTokens: outputTokens))
            emit(ProxyTranslator.messageStopEvent())
        }
        close()
    }

    private func handleLine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        if let delta = first["delta"] as? [String: Any] {
            // Text delta
            if let text = delta["content"] as? String, !text.isEmpty {
                if !textBlockStarted {
                    let idx = nextBlockIndex
                    nextBlockIndex += 1
                    emit(ProxyTranslator.textBlockStart(index: idx))
                    textBlockStarted = true
                }
                outputTokens += max(1, text.count / 4)
                emit(ProxyTranslator.textBlockDelta(index: 0, text: text))
            }

            // Tool-call deltas
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                // Close text block before opening tool blocks (Anthropic schema).
                if textBlockStarted && !textBlockClosed {
                    emit(ProxyTranslator.blockStop(index: 0))
                    textBlockClosed = true
                }
                for tc in toolCalls {
                    handleToolCallDelta(tc)
                }
            }
        }

        if let reason = first["finish_reason"] as? String {
            switch reason {
            case "length":     stopReason = "max_tokens"
            case "tool_calls": stopReason = "tool_use"
            case "stop":       stopReason = "end_turn"
            default:           break
            }
        }
    }

    private func handleToolCallDelta(_ tc: [String: Any]) {
        let callIdx = (tc["index"] as? Int) ?? 0
        let blockIdx: Int
        if let existing = toolBlockIndexByCallIndex[callIdx] {
            blockIdx = existing
        } else {
            blockIdx = nextBlockIndex
            nextBlockIndex += 1
            toolBlockIndexByCallIndex[callIdx] = blockIdx
        }
        let function = tc["function"] as? [String: Any] ?? [:]
        let rawId = (tc["id"] as? String) ?? ProxyTranslator.makeToolUseId()
        let id = rawId.hasPrefix("toolu_") ? rawId : "toolu_\(rawId)"
        let name = (function["name"] as? String) ?? ""

        // Open the content block on the first delta for this call (need name).
        if !openedToolCallIndices.contains(callIdx) && !name.isEmpty {
            emit(ProxyTranslator.toolUseBlockStart(index: blockIdx, id: id, name: name))
            openedToolCallIndices.insert(callIdx)
        }
        // Stream argument JSON deltas.
        if openedToolCallIndices.contains(callIdx),
           let args = function["arguments"] as? String, !args.isEmpty {
            emit(ProxyTranslator.toolUseBlockDelta(index: blockIdx, partialJSON: args))
            outputTokens += max(1, args.count / 4)
        }
    }
}

// MARK: - Ollama NDJSON → Anthropic SSE translator (text-only)

/// Ollama can also return tool calls in newer versions, but format support
/// varies by model. For now we translate only the text path; tool-using flows
/// should pick LM Studio.
final class OllamaStreamTranslator: NSObject, URLSessionDataDelegate {
    var task: URLSessionDataTask?
    private let emit: (Data) -> Void
    private let close: () -> Void
    private var lineBuffer = ""
    private var textBlockStarted = false
    private var stopReason = "end_turn"
    private var outputTokens = 0

    init(emit: @escaping (Data) -> Void, close: @escaping () -> Void) {
        self.emit = emit
        self.close = close
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lineBuffer += s
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if textBlockStarted {
            emit(ProxyTranslator.blockStop(index: 0))
        }
        if let error = error {
            emit(ProxyTranslator.sseEvent("error", ["type": "error", "error": ["type": "api_error", "message": error.localizedDescription]]))
        } else {
            emit(ProxyTranslator.messageDeltaEvent(stopReason: stopReason, outputTokens: outputTokens))
            emit(ProxyTranslator.messageStopEvent())
        }
        close()
    }

    private func handleLine(_ line: String) {
        if line.isEmpty { return }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let msg = obj["message"] as? [String: Any], let c = msg["content"] as? String, !c.isEmpty {
            if !textBlockStarted {
                emit(ProxyTranslator.textBlockStart(index: 0))
                textBlockStarted = true
            }
            outputTokens += max(1, c.count / 4)
            emit(ProxyTranslator.textBlockDelta(index: 0, text: c))
        }
        if let done = obj["done"] as? Bool, done,
           let reason = obj["done_reason"] as? String, reason == "length" {
            stopReason = "max_tokens"
        }
    }
}
