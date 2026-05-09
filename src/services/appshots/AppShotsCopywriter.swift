import Foundation

// Offline per-category subtitle variation so 8 sets don't look identical.
// Headline is echoed verbatim. If the user supplied a subtitle we use it — never overwritten.

enum AppShotsCopywriter {
    private static let subtitleBank: [String: [String]] = [
        "bold": ["Built for people who ship.", "Move fast. Finish strong.", "Zero friction, all signal."],
        "minimal": ["Less noise. More focus.", "Simple by design.", "Only what matters."],
        "elegant": ["A calmer way to work.", "Crafted for the details.", "Quiet power, everyday."],
        "playful": ["Your day, but way better.", "Tap in. Have fun.", "Small app, big wins."],
        "professional": ["The toolkit serious teams trust.", "Enterprise-grade, human-friendly.", "Reliable, fast, and measurable."],
        "showcase": ["See it. Love it. Share it.", "Designed to be shown off.", "Beautifully yours."],
        "custom": ["Made just for you.", "Your app, your way."]
    ]

    static func copy(base: String, userSubtitle: String?, category: String, seed: String) -> (headline: String, subtitle: String?) {
        if let userSubtitle, !userSubtitle.isEmpty {
            return (base, userSubtitle)
        }
        let bank = subtitleBank[category.lowercased()] ?? subtitleBank["custom"] ?? []
        guard !bank.isEmpty else { return (base, nil) }
        let index = abs(seed.hashValue) % bank.count
        return (base, bank[index])
    }
}
