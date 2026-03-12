import Foundation

/// Handles device interactions (tap, swipe, text, button, key) via idb/WDA
actor DeviceInteractionService {
    private let idb = IDBClient()

    enum DeviceType {
        case simulator
        case physical(wdaSessionId: String)
    }

    /// Execute a device action
    func execute(_ action: DeviceAction, udid: String, deviceType: DeviceType = .simulator) async throws -> String? {
        switch deviceType {
        case .simulator:
            return try await executeOnSimulator(action, udid: udid)
        case .physical(let sessionId):
            return try await executeOnPhysicalDevice(action, sessionId: sessionId)
        }
    }

    // MARK: - Simulator Actions (via idb shell)

    private func executeOnSimulator(_ action: DeviceAction, udid: String) async throws -> String? {
        switch action {
        case .tap(let x, let y, let duration):
            try await idb.tap(udid: udid, x: x, y: y, duration: duration)
            return nil

        case .swipe(let fromX, let fromY, let toX, let toY, let duration, let delta):
            try await idb.swipe(udid: udid, fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: duration, delta: delta.map { Int($0) })
            return nil

        case .button(let buttonType, _):
            try await idb.pressButton(udid: udid, button: buttonType.rawValue)
            return nil

        case .inputText(let text):
            try await idb.inputText(udid: udid, text: text)
            return nil

        case .key(let keyInput, let duration):
            switch keyInput {
            case .keycode(let code):
                try await idb.pressKey(udid: udid, keycode: code, duration: duration)
            case .character(let char):
                try await idb.inputText(udid: udid, text: char)
            }
            return nil

        case .keySequence(let keys):
            var keycodes: [Int] = []
            for key in keys {
                switch key {
                case .keycode(let code):
                    keycodes.append(code)
                case .character(let char):
                    // Flush any accumulated keycodes first
                    if !keycodes.isEmpty {
                        try await idb.pressKeySequence(udid: udid, keys: keycodes)
                        keycodes = []
                    }
                    try await idb.inputText(udid: udid, text: char)
                }
            }
            if !keycodes.isEmpty {
                try await idb.pressKeySequence(udid: udid, keys: keycodes)
            }
            return nil

        case .describeAll:
            return try await idb.describeAll(udid: udid)

        case .describePoint(let x, let y, _):
            return try await idb.describePoint(udid: udid, x: Int(x), y: Int(y))
        }
    }

    // MARK: - Physical Device Actions (via WDA)

    private func executeOnPhysicalDevice(_ action: DeviceAction, sessionId: String) async throws -> String? {
        let wda = WDAClient()

        switch action {
        case .tap(let x, let y, _):
            try await wda.tap(sessionId: sessionId, x: x, y: y)
            return nil

        case .swipe(let fromX, let fromY, let toX, let toY, let duration, _):
            try await wda.swipe(sessionId: sessionId, fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: Int((duration ?? 0.3) * 1000))
            return nil

        case .button(let buttonType, _):
            try await wda.pressButton(sessionId: sessionId, button: buttonType.rawValue)
            return nil

        case .inputText(let text):
            try await wda.inputText(sessionId: sessionId, text: text)
            return nil

        case .key, .keySequence:
            return nil

        case .describeAll:
            return try await wda.source(sessionId: sessionId)

        case .describePoint:
            return try await wda.source(sessionId: sessionId)
        }
    }
}
