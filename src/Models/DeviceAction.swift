import Foundation

/// Device action types matching device-actions.types.ts
enum DeviceAction {
    case tap(x: Double, y: Double, duration: Double? = nil)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double? = nil, delta: Double? = nil)
    case button(ButtonType, duration: Double? = nil)
    case inputText(String)
    case key(KeyInput, duration: Double? = nil)
    case keySequence([KeyInput])
    case describeAll(nested: Bool = false)
    case describePoint(x: Int, y: Int, nested: Bool = false)

    enum ButtonType: String, Codable, Sendable {
        case home = "HOME"
        case lock = "LOCK"
        case sideButton = "SIDE_BUTTON"
        case applePay = "APPLE_PAY"
        case siri = "SIRI"
    }

    enum KeyInput: Codable, Sendable {
        case keycode(Int)
        case character(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let code = try? container.decode(Int.self) {
                self = .keycode(code)
            } else if let char = try? container.decode(String.self) {
                self = .character(char)
            } else {
                throw DecodingError.typeMismatch(KeyInput.self, .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected Int or String"
                ))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .keycode(let code): try container.encode(code)
            case .character(let char): try container.encode(char)
            }
        }
    }
}
