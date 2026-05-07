import Foundation

/// Minimal HTTP/1.1 request representation.
struct HTTPRequest {
    var method: String
    var path: String
    var version: String
    var headers: [(String, String)]
    var body: Data

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower { return v }
        return nil
    }
}

/// Incremental parser. Feed bytes via `append(_:)` until `parse()` returns a request.
final class HTTPRequestParser {
    private var buffer = Data()
    private var headersParsed = false
    private var method = ""
    private var path = ""
    private var version = "HTTP/1.1"
    private var headers: [(String, String)] = []
    private var contentLength: Int = 0
    private var bodyStart: Int = 0

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns a parsed request if complete; otherwise nil (need more bytes).
    func parse() -> HTTPRequest? {
        if !headersParsed {
            guard let headerEnd = findHeaderEnd() else { return nil }
            let headerBytes = buffer.prefix(headerEnd)
            guard let headerStr = String(data: headerBytes, encoding: .utf8) else { return nil }
            let lines = headerStr.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 3 else { return nil }
            method = String(parts[0])
            path = String(parts[1])
            version = String(parts[2])
            headers.removeAll()
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[line.startIndex..<colon])
                let valueStart = line.index(after: colon)
                let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
                headers.append((name, value))
            }
            if let cl = headers.first(where: { $0.0.lowercased() == "content-length" })?.1,
               let n = Int(cl) {
                contentLength = n
            }
            bodyStart = headerEnd + 4 // \r\n\r\n
            headersParsed = true
        }
        let available = buffer.count - bodyStart
        if available < contentLength { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        let req = HTTPRequest(method: method, path: path, version: version, headers: headers, body: body)
        // Reset for next request on same connection.
        let consumed = bodyStart + contentLength
        buffer.removeSubrange(0..<consumed)
        headersParsed = false
        contentLength = 0
        bodyStart = 0
        headers.removeAll()
        return req
    }

    private func findHeaderEnd() -> Int? {
        // Find \r\n\r\n
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let bytes = [UInt8](buffer)
        guard bytes.count >= needle.count else { return nil }
        for i in 0...(bytes.count - needle.count) {
            if Array(bytes[i..<i+needle.count]) == needle { return i }
        }
        return nil
    }
}

enum HTTPResponse {
    static func make(status: Int, statusText: String, headers: [(String, String)], body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        var hasLength = false
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
            if k.lowercased() == "content-length" { hasLength = true }
        }
        if !hasLength {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    static func sseHead() -> Data {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        return Data(head.utf8)
    }

    static func json(_ obj: Any, status: Int = 200) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return make(status: status, statusText: status == 200 ? "OK" : "Error",
                    headers: [("Content-Type", "application/json")], body: body)
    }
}
