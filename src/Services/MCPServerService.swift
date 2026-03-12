import Foundation

/// MCP (Model Context Protocol) HTTP server for Claude Code integration
/// Port of server/mcp/mcp-server.ts
actor MCPServerService {
    private var acceptSource: DispatchSourceRead?
    private var serverSocket: Int32 = -1
    private(set) var port: Int = 0
    private(set) var isRunning = false

    private let toolExecutor: MCPToolExecutor

    private static var portFileURL: URL {
        BlitzPaths.mcpPort
    }

    init(appState: AppState) {
        self.toolExecutor = MCPToolExecutor(appState: appState)

        // Store executor reference in AppState for approval resolution
        Task { @MainActor in
            appState.toolExecutor = self.toolExecutor
        }
    }

    /// Start the MCP server on a free port
    func start() async throws {
        let assignedPort = PortAllocator.findFreePort()
        guard assignedPort > 0 else {
            throw MCPError.noPortAvailable
        }
        self.port = Int(assignedPort)

        // Create TCP socket
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPError.socketCreationFailed }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(assignedPort).bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw MCPError.bindFailed
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw MCPError.listenFailed
        }

        serverSocket = fd
        isRunning = true

        // Write port file for bridge script
        writePortFile(port: Int(assignedPort))

        print("[MCP] Server listening on port \(assignedPort)")

        // Accept connections in background using DispatchSource
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(fd, sockPtr, &addrLen)
                }
            }
            if clientFd < 0 { return }
            Task { [weak self] in
                await self?.handleConnection(clientFd)
            }
        }
        source.resume()
        self.acceptSource = source as? DispatchSource
    }

    /// Stop the MCP server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        isRunning = false
        removePortFile()
    }

    /// Handle a single client connection
    private func handleConnection(_ fd: Int32) async {
        defer { close(fd) }

        // Read HTTP request with larger buffer for tool arguments
        var requestData = Data()
        let bufSize = 65536
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        // Read until we have the full body
        var totalRead = 0
        var contentLength = -1

        while true {
            let bytesRead = recv(fd, buf, bufSize, 0)
            guard bytesRead > 0 else { break }
            requestData.append(buf, count: bytesRead)
            totalRead += bytesRead

            // Parse content-length from headers if not yet found
            if contentLength < 0, let str = String(data: requestData, encoding: .utf8) {
                if let range = str.range(of: "\r\n\r\n") {
                    let headers = String(str[..<range.lowerBound]).lowercased()
                    if let clRange = headers.range(of: "content-length: ") {
                        let afterCL = headers[clRange.upperBound...]
                        if let endLine = afterCL.firstIndex(of: "\r") ?? afterCL.firstIndex(of: "\n") {
                            contentLength = Int(afterCL[..<endLine]) ?? 0
                        }
                    }
                    let headerSize = str.distance(from: str.startIndex, to: range.upperBound)
                    let bodySize = requestData.count - headerSize
                    if contentLength <= 0 || bodySize >= contentLength { break }
                } else {
                    continue // Haven't received full headers yet
                }
            } else if contentLength >= 0 {
                // Check if we have enough body data
                if let str = String(data: requestData, encoding: .utf8),
                   let range = str.range(of: "\r\n\r\n") {
                    let headerSize = str.distance(from: str.startIndex, to: range.upperBound)
                    let bodySize = requestData.count - headerSize
                    if bodySize >= contentLength { break }
                }
            } else {
                break
            }
        }

        guard let requestStr = String(data: requestData, encoding: .utf8) else { return }

        // Parse HTTP request line
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }

        let method = parts[0]
        let path = parts[1]

        // Extract body (after \r\n\r\n)
        var body: Data?
        if let range = requestStr.range(of: "\r\n\r\n") {
            let bodyStr = String(requestStr[range.upperBound...])
            if !bodyStr.isEmpty {
                body = Data(bodyStr.utf8)
            }
        }

        // Route request
        let responseBody: String
        do {
            responseBody = try await routeRequest(method: method, path: path, body: body)
        } catch {
            let escapedError = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let errorJson = "{\"error\": \"\(escapedError)\"}"
            sendHTTPResponse(fd: fd, statusCode: 500, body: errorJson)
            return
        }

        sendHTTPResponse(fd: fd, statusCode: 200, body: responseBody)
    }

    /// Route MCP requests to handlers
    private func routeRequest(method: String, path: String, body: Data?) async throws -> String {
        // MCP Streamable HTTP transport — handle JSON-RPC messages
        if path == "/mcp" && method == "POST" {
            guard let body else { throw MCPError.missingBody }
            return try await handleMCPRequest(body)
        }

        return "{\"error\": \"Not found\"}"
    }

    /// Handle MCP JSON-RPC request
    private func handleMCPRequest(_ body: Data) async throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let methodName = json["method"] as? String,
              let id = json["id"] else {
            throw MCPError.invalidRequest
        }

        let params = json["params"] as? [String: Any] ?? [:]

        let result: Any
        switch methodName {
        case "initialize":
            result = [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "blitz-mcp",
                    "version": "1.0.0"
                ]
            ] as [String: Any]

        case "notifications/initialized":
            // Client acknowledgment — no response needed but we return empty result
            result = [:] as [String: Any]

        case "tools/list":
            result = [
                "tools": MCPToolRegistry.allTools()
            ]

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let toolArgs = params["arguments"] as? [String: Any] ?? [:]
            result = try await toolExecutor.execute(name: toolName, arguments: toolArgs)

        default:
            throw MCPError.unknownMethod(methodName)
        }

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]

        let data = try JSONSerialization.data(withJSONObject: response)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Send HTTP response
    private func sendHTTPResponse(fd: Int32, statusCode: Int, body: String) {
        let statusText = statusCode == 200 ? "OK" : "Error"
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        let data = Data(response.utf8)
        data.withUnsafeBytes { buf in
            _ = send(fd, buf.baseAddress!, buf.count, 0)
        }
    }

    // MARK: - Port File

    private func writePortFile(port: Int) {
        let url = Self.portFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(port)".write(to: url, atomically: true, encoding: .utf8)
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(at: Self.portFileURL)
    }

    enum MCPError: Error, LocalizedError {
        case noPortAvailable
        case socketCreationFailed
        case bindFailed
        case listenFailed
        case missingBody
        case invalidRequest
        case unknownMethod(String)
        case unknownTool(String)
        case invalidToolArgs

        var errorDescription: String? {
            switch self {
            case .noPortAvailable: return "No port available for MCP server"
            case .socketCreationFailed: return "Failed to create MCP server socket"
            case .bindFailed: return "Failed to bind MCP server port"
            case .listenFailed: return "Failed to listen on MCP server port"
            case .missingBody: return "Missing request body"
            case .invalidRequest: return "Invalid MCP request"
            case .unknownMethod(let m): return "Unknown MCP method: \(m)"
            case .unknownTool(let t): return "Unknown MCP tool: \(t)"
            case .invalidToolArgs: return "Invalid tool arguments"
            }
        }
    }
}
