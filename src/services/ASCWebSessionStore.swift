import CryptoKit
import Foundation

struct ASCWebSessionStore: Codable {
    static let keychainService = "asc-web-session"
    static let keychainAccount = "asc:web-session:store"
    static let version = 1

    struct Session: Codable {
        let version: Int
        let updatedAt: Date
        let userEmail: String?
        let cookies: [String: [Cookie]]

        private enum CodingKeys: String, CodingKey {
            case version
            case updatedAt = "updated_at"
            case userEmail = "user_email"
            case cookies
        }
    }

    struct Cookie: Codable {
        let name: String
        let value: String
        let path: String
        let domain: String
        let expires: Date?
        let maxAge: Int?
        let secure: Bool
        let httpOnly: Bool
        let sameSite: Int?

        private enum CodingKeys: String, CodingKey {
            case name
            case value
            case path
            case domain
            case expires
            case maxAge = "max_age"
            case secure
            case httpOnly = "http_only"
            case sameSite = "same_site"
        }
    }

    let version: Int
    var lastKey: String?
    var sessions: [String: Session]

    private enum CodingKeys: String, CodingKey {
        case version
        case lastKey = "last_key"
        case sessions
    }

    private static let baseURLs = [
        "https://appstoreconnect.apple.com/",
        "https://idmsa.apple.com/",
        "https://gsa.apple.com/",
    ]

    static func mergedData(
        storing session: IrisSession,
        into existingData: Data?,
        now: Date = Date()
    ) throws -> Data {
        var store = try decode(existingData) ?? ASCWebSessionStore(version: version, lastKey: nil, sessions: [:])
        let key = sessionKey(forEmail: session.email)
        store.sessions[key] = Session(
            version: version,
            updatedAt: now,
            userEmail: normalizedEmail(session.email),
            cookies: persistedCookies(from: session.cookies)
        )
        store.lastKey = key
        return try encode(store)
    }

    static func removingSession(
        email: String?,
        from existingData: Data?
    ) throws -> Data? {
        guard var store = try decode(existingData) else { return nil }

        let key = if let email, !normalizedEmail(email).isEmpty {
            sessionKey(forEmail: email)
        } else {
            store.lastKey ?? ""
        }

        guard !key.isEmpty else { return existingData }

        store.sessions.removeValue(forKey: key)
        if store.sessions.isEmpty {
            return nil
        }

        if store.lastKey == key {
            store.lastKey = mostRecentSessionKey(in: store.sessions)
        }

        return try encode(store)
    }

    private static func normalizedEmail(_ email: String?) -> String {
        (email ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sessionKey(forEmail email: String?) -> String {
        let digest = SHA256.hash(data: Data(normalizedEmail(email).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func persistedCookies(from cookies: [IrisSession.IrisCookie]) -> [String: [Cookie]] {
        var buckets: [String: [Cookie]] = [:]

        for cookie in cookies {
            let persistedCookie = Cookie(
                name: cookie.name,
                value: cookie.value,
                path: cookie.path.isEmpty ? "/" : cookie.path,
                domain: cookie.domain,
                expires: nil,
                maxAge: nil,
                secure: true,
                httpOnly: true,
                sameSite: nil
            )

            let matchingBases = baseURLs.filter { baseURL in
                guard let host = URL(string: baseURL)?.host else { return false }
                return cookieMatches(host: host, domain: cookie.domain)
            }

            for baseURL in matchingBases {
                buckets[baseURL, default: []].append(persistedCookie)
            }
        }

        return buckets
    }

    private static func cookieMatches(host: String, domain: String) -> Bool {
        let normalizedHost = host.lowercased()
        let normalizedDomain = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !normalizedDomain.isEmpty else { return false }
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
    }

    private static func mostRecentSessionKey(in sessions: [String: Session]) -> String? {
        sessions.max { lhs, rhs in
            if lhs.value.updatedAt == rhs.value.updatedAt {
                return lhs.key < rhs.key
            }
            return lhs.value.updatedAt < rhs.value.updatedAt
        }?.key
    }

    private static func decode(_ data: Data?) throws -> ASCWebSessionStore? {
        guard let data, !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ASCWebSessionStore.self, from: data)
    }

    private static func encode(_ store: ASCWebSessionStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(store)
    }
}
