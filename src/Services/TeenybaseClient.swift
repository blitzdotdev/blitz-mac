import Foundation

actor TeenybaseClient {
    private var baseURL: String = ""
    private var token: String = ""
    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    func configure(baseURL: String, token: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.token = token
    }

    // MARK: - Health

    func healthCheck() async throws -> Bool {
        let data = try await get("/health")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["status"] as? String == "ok"
    }

    // MARK: - Schema

    func fetchSchema() async throws -> TeenybaseSettingsResponse {
        let data = try await get("/settings?raw=true")
        return try decoder.decode(TeenybaseSettingsResponse.self, from: data)
    }

    // MARK: - CRUD

    func listRecords(
        table: String,
        limit: Int = 50,
        offset: Int = 0,
        orderBy: String? = nil,
        ascending: Bool = true,
        where whereClause: String? = nil
    ) async throws -> PaginatedResponse {
        var body: [String: Any] = [
            "limit": limit,
            "offset": offset
        ]
        if let orderBy {
            body["order"] = "\(orderBy) \(ascending ? "asc" : "desc")"
        }
        if let whereClause, !whereClause.isEmpty {
            body["where"] = whereClause
        }
        let data = try await post("/table/\(table)/list", body: body)
        return try decoder.decode(PaginatedResponse.self, from: data)
    }

    func insertRecord(table: String, values: [String: Any]) async throws -> [TableRow] {
        let body: [String: Any] = [
            "values": values,
            "returning": "*"
        ]
        let data = try await post("/table/\(table)/insert", body: body)
        return try decoder.decode([TableRow].self, from: data)
    }

    func updateRecord(table: String, id: String, values: [String: Any]) async throws -> TableRow {
        let data = try await post("/table/\(table)/edit/\(id)?returning=*", body: values)
        return try decoder.decode(TableRow.self, from: data)
    }

    func deleteRecord(table: String, id: String) async throws -> [TableRow] {
        let escapedId = id.replacingOccurrences(of: "'", with: "''")
        let body: [String: Any] = [
            "where": "id='\(escapedId)'"
        ]
        let data = try await post("/table/\(table)/delete", body: body)
        return try decoder.decode([TableRow].self, from: data)
    }

    // MARK: - HTTP Helpers

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: baseURL + "/api/v1" + path) else {
            throw TeenybaseError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + "/api/v1" + path) else {
            throw TeenybaseError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TeenybaseError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TeenybaseError.httpError(statusCode: http.statusCode, message: message)
        }
    }
}

enum TeenybaseError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        }
    }
}
