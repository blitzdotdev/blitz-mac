import Foundation

enum ASCError: LocalizedError {
    case invalidURL
    case notFound(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .notFound(let what):
            return "\(what) not found"
        case .httpError(let code, let body):
            return "HTTP \(code): \(Self.parseErrorMessages(body))"
        }
    }

    var isConflict: Bool {
        if case .httpError(409, _) = self { return true }
        return false
    }

    var isProgramLicenseAgreementRequired: Bool {
        guard case let .httpError(statusCode, body) = self,
              statusCode == 403 else {
            return false
        }

        let combined = "\(Self.parseErrorMessages(body))\n\(body)".lowercased()
        return combined.contains("program license agreement")
            || combined.contains("membership resource")
            || combined.contains("account holder")
            || combined.contains("latest agreement")
    }

    var programLicenseAgreementMessage: String {
        "Your team's Account Holder must accept the latest Apple Developer Program License Agreement before Blitz can continue this App Store Connect action."
    }

    private static func parseErrorMessages(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]] else {
            return String(body.prefix(300))
        }

        var messages: [String] = []
        for error in errors {
            if let detail = error["detail"] as? String {
                messages.append(detail)
            } else if let title = error["title"] as? String {
                messages.append(title)
            }

            if let meta = error["meta"] as? [String: Any],
               let associatedErrors = meta["associatedErrors"] as? [String: [[String: Any]]] {
                for (_, subErrors) in associatedErrors {
                    for subError in subErrors {
                        if let detail = subError["detail"] as? String {
                            messages.append(detail)
                        } else if let title = subError["title"] as? String {
                            messages.append(title)
                        }
                    }
                }
            }
        }

        return messages.isEmpty ? String(body.prefix(300)) : messages.joined(separator: "\n")
    }
}
