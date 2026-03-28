import Foundation

enum IrisError: Error, LocalizedError {
    case sessionExpired
    case noSession
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "Apple ID session expired. Please sign in again."
        case .noSession: return "No Apple ID session available."
        case .requestFailed(let code, let msg): return "Iris API error \(code): \(msg)"
        }
    }
}

/// Result of fetching messages — includes sideloaded rejections from `included`.
struct IrisMessagesResult {
    let messages: [IrisResolutionCenterMessage]
    let rejections: [IrisReviewRejection]
}

struct IrisRawPage {
    let url: String
    let data: Data
}

/// Client for Apple's internal iris API (appstoreconnect.apple.com/iris/v1).
/// Uses Apple ID session cookies captured from WKWebView login.
actor IrisService {
    private let session: IrisSession
    private let urlSession: URLSession
    private let cookieHeader: String
    private static let baseURL = "https://appstoreconnect.apple.com/iris/v1"

    init(session: IrisSession) {
        self.session = session
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        self.urlSession = URLSession(configuration: config)

        let header = session.cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        self.cookieHeader = header

        irisLog("IrisService: init with \(session.cookies.count) cookies, header length=\(header.count)")
    }

    // MARK: - Public API

    func fetchResolutionCenterThreadPages(appId: String) async throws -> [IrisRawPage] {
        let url = "\(Self.baseURL)/apps/\(appId)/resolutionCenterThreads"
        irisLog("IrisService: fetchResolutionCenterThreadPages appId=\(appId)")
        return try await fetchAllPages(startingAt: url)
    }

    func fetchResolutionCenterThreads(appId: String) async throws -> [IrisResolutionCenterThread] {
        let pages = try await fetchResolutionCenterThreadPages(appId: appId)
        let threads = pages.flatMap { page in
            (try? JSONDecoder().decode(IrisListResponse<IrisResolutionCenterThread>.self, from: page.data).data) ?? []
        }
        irisLog("IrisService: fetchResolutionCenterThreads got \(threads.count) threads")
        return threads
    }

    func fetchMessagesAndRejectionsPages(threadId: String) async throws -> [IrisRawPage] {
        let url = "\(Self.baseURL)/resolutionCenterThreads/\(threadId)/resolutionCenterMessages?include=fromActor,rejections,resolutionCenterMessageAttachments"
        irisLog("IrisService: fetchMessagesAndRejectionsPages threadId=\(threadId)")
        return try await fetchAllPages(startingAt: url)
    }

    /// Fetches messages for a thread. The `?include=rejections` param causes Apple
    /// to sideload `reviewRejections` objects in the `included` array, so we parse
    /// both messages and rejections from a single response.
    func fetchMessagesAndRejections(threadId: String) async throws -> IrisMessagesResult {
        let pages = try await fetchMessagesAndRejectionsPages(threadId: threadId)
        var messages: [IrisResolutionCenterMessage] = []
        var rejectionsById: [String: IrisReviewRejection] = [:]

        for page in pages {
            let messagesResponse = try JSONDecoder().decode(IrisListResponse<IrisResolutionCenterMessage>.self, from: page.data)
            irisLog("IrisService: got \(messagesResponse.data.count) messages from \(page.url)")
            messages.append(contentsOf: messagesResponse.data)

            let fullResponse = try JSONDecoder().decode(IrisIncludedResponse.self, from: page.data)
            let rejections = fullResponse.included?.filter { $0.type == "reviewRejections" } ?? []
            irisLog("IrisService: got \(rejections.count) rejection objects from included, \(fullResponse.included?.count ?? 0) total included")

            for item in rejections {
                if let itemData = try? JSONEncoder().encode(item),
                   let rejection = try? JSONDecoder().decode(IrisReviewRejection.self, from: itemData) {
                    irisLog("IrisService: parsed rejection \(rejection.id), reasons=\(rejection.attributes.reasons?.count ?? 0)")
                    rejectionsById[rejection.id] = rejection
                }
            }
        }

        return IrisMessagesResult(
            messages: messages,
            rejections: Array(rejectionsById.values)
        )
    }

    // MARK: - HTTP

    private func fetchAllPages(startingAt startURL: String) async throws -> [IrisRawPage] {
        var pages: [IrisRawPage] = []
        var nextURL: String? = startURL
        var seenURLs: Set<String> = []

        while let currentURL = nextURL {
            guard seenURLs.insert(currentURL).inserted else {
                irisLog("IrisService.fetchAllPages: stopping on repeated next URL \(currentURL)")
                break
            }

            let data = try await getRaw(currentURL)
            pages.append(IrisRawPage(url: currentURL, data: data))
            nextURL = nextURLString(from: data)
        }

        return pages
    }

    private func getRaw(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            irisLog("IrisService.get: invalid URL \(urlString)")
            throw IrisError.requestFailed(0, "Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://appstoreconnect.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://appstoreconnect.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        irisLog("IrisService.get: requesting \(urlString)")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            irisLog("IrisService.get: non-HTTP response")
            throw IrisError.requestFailed(0, "Non-HTTP response")
        }

        irisLog("IrisService.get: HTTP \(httpResponse.statusCode), body length=\(data.count)")

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            let body = String(data: data, encoding: .utf8) ?? ""
            irisLog("IrisService.get: auth error, body=\(String(body.prefix(500)))")
            throw IrisError.sessionExpired
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            irisLog("IrisService.get: error \(httpResponse.statusCode), body=\(String(body.prefix(1000)))")
            throw IrisError.requestFailed(httpResponse.statusCode, body)
        }

        if let bodyStr = String(data: data, encoding: .utf8) {
            irisLog("IrisService.get: response body=\(String(bodyStr.prefix(2000)))")
        }

        return data
    }

    private func get<T: Decodable>(_ urlString: String) async throws -> T {
        let data = try await getRaw(urlString)
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            irisLog("IrisService.get: decode success")
            return decoded
        } catch {
            irisLog("IrisService.get: decode FAILED: \(error)")
            throw error
        }
    }

    private func nextURLString(from data: Data) -> String? {
        (try? JSONDecoder().decode(IrisLinksResponse.self, from: data).links?.next)
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Iris JSON:API Response Wrappers

struct IrisListResponse<T: Decodable>: Decodable {
    let data: [T]
}

/// Generic included item — we decode type/id/attributes as raw JSON, then
/// re-decode specific types (reviewRejections) from the raw data.
struct IrisIncludedItem: Codable {
    let type: String
    let id: String
    let attributes: AnyCodable?
}

struct IrisIncludedResponse: Decodable {
    let included: [IrisIncludedItem]?
}

struct IrisLinksResponse: Decodable {
    let links: Links?

    struct Links: Decodable {
        let next: String?
    }
}

/// Minimal type-erased Codable wrapper for arbitrary JSON.
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable(value: $0) })
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable(value: $0) })
        case let str as String:
            try container.encode(str)
        case let num as Double:
            try container.encode(num)
        case let bool as Bool:
            try container.encode(bool)
        default:
            try container.encodeNil()
        }
    }

    init(value: Any) {
        self.value = value
    }
}
