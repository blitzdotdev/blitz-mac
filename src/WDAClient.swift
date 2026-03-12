import Foundation

/// HTTP client for WebDriverAgent API (physical device interaction)
actor WDAClient {
    private let baseURL: URL
    private let session: URLSession

    init(host: String = "localhost", port: Int = 8100) {
        guard let url = URL(string: "http://\(host):\(port)") else {
            preconditionFailure("Invalid WDA host/port: \(host):\(port)")
        }
        self.baseURL = url
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - Session

    struct SessionResponse: Codable, Sendable {
        let value: SessionValue
    }

    struct SessionValue: Codable, Sendable {
        let sessionId: String?
    }

    func createSession() async throws -> String {
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": [
                    "platformName": "iOS"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response: SessionResponse = try await post("/session", body: data)
        guard let sessionId = response.value.sessionId else {
            throw WDAError.noSession
        }
        return sessionId
    }

    // MARK: - Device Actions

    func tap(sessionId: String, x: Double, y: Double) async throws {
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 50],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        try await post("/session/\(sessionId)/actions", body: data, ignoreResponse: true)
    }

    func swipe(sessionId: String, fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Int = 300) async throws {
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(fromX), "y": Int(fromY)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pointerMove", "duration": duration, "x": Int(toX), "y": Int(toY)],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        try await post("/session/\(sessionId)/actions", body: data, ignoreResponse: true)
    }

    func pressButton(sessionId: String, button: String) async throws {
        let wdaButton: String
        switch button.lowercased() {
        case "home": wdaButton = "home"
        case "lock", "side_button": wdaButton = "lock"
        case "volumeup": wdaButton = "volumeUp"
        case "volumedown": wdaButton = "volumeDown"
        default: wdaButton = button
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": wdaButton])
        try await post("/session/\(sessionId)/wda/pressButton", body: body, ignoreResponse: true)
    }

    func inputText(sessionId: String, text: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "value": Array(text).map { String($0) }
        ])
        try await post("/session/\(sessionId)/keys", body: body, ignoreResponse: true)
    }

    func screenshot(sessionId: String) async throws -> Data {
        struct ScreenshotResponse: Codable {
            let value: String
        }
        let response: ScreenshotResponse = try await get("/session/\(sessionId)/screenshot")
        guard let data = Data(base64Encoded: response.value) else {
            throw WDAError.invalidScreenshot
        }
        return data
    }

    /// Get the accessibility tree (source)
    func source(sessionId: String) async throws -> String {
        struct SourceResponse: Codable {
            let value: String
        }
        let response: SourceResponse = try await get("/session/\(sessionId)/source")
        return response.value
    }

    /// Health check
    func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("status")
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - HTTP Helpers

    private func get<T: Codable>(_ path: String) async throws -> T {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(cleanPath)
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw WDAError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func post<T: Codable>(_ path: String, body: Data) async throws -> T {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(cleanPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw WDAError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: Data, ignoreResponse: Bool) async throws {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(cleanPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw WDAError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}

enum WDAError: Error, LocalizedError {
    case noSession
    case httpError(statusCode: Int)
    case invalidScreenshot

    var errorDescription: String? {
        switch self {
        case .noSession: return "Failed to create WDA session"
        case .httpError(let code): return "WDA HTTP error: \(code)"
        case .invalidScreenshot: return "Invalid screenshot data"
        }
    }
}
