import Foundation

// MARK: - Dynamic JSON Value

enum AnyCodableValue: Codable, Hashable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .null: return "NULL"
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Teenybase Schema Types

typealias TableRow = [String: AnyCodableValue]

struct TeenybaseField: Codable, Identifiable {
    let name: String
    let sqlType: String?
    let type: String?
    let primary: Bool?
    let notNull: Bool?
    let unique: Bool?
    let autoIncrement: Bool?
    let `default`: AnyCodableValue?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, sqlType, type, primary, notNull, unique, autoIncrement
        case `default` = "default"
    }
}

struct TeenybaseTable: Codable, Identifiable, Hashable {
    let name: String
    let fields: [TeenybaseField]
    let autoSetUid: Bool?

    var id: String { name }

    static func == (lhs: TeenybaseTable, rhs: TeenybaseTable) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

struct TeenybaseSettingsResponse: Codable {
    let tables: [TeenybaseTable]
    let jwtSecret: String?
    let appUrl: String?
    let version: Int?
}

struct PaginatedResponse: Codable {
    let items: [TableRow]
    let total: Int
}

// MARK: - Connection Status

enum ConnectionStatus: String {
    case disconnected
    case connecting
    case connected
    case error
}
