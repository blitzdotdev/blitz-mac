import Foundation

// Pure, offline copy variation for the onboarding batch.
//
// We keep the user's headline intact (transforming it risks cringe) and instead
// vary the subtitle per template category so the 8 sets don't look identical.
// If the user typed a subtitle explicitly, we respect it verbatim.

enum AppShotsCopywriter {
    /// Deterministic per-category subtitle bank. Index chosen by a stable hash
    /// of the app name so re-generations stay consistent across runs.
    private static let subtitleBank: [String: [String]] = [
        "bold": [
            "Built for people who ship.",
            "Move fast. Finish strong.",
            "Zero friction, all signal."
        ],
        "minimal": [
            "Less noise. More focus.",
            "Simple by design.",
            "Only what matters."
        ],
        "elegant": [
            "A calmer way to work.",
            "Crafted for the details.",
            "Quiet power, everyday."
        ],
        "playful": [
            "Your day, but way better.",
            "Tap in. Have fun.",
            "Small app, big wins."
        ],
        "professional": [
            "The toolkit serious teams trust.",
            "Enterprise-grade, human-friendly.",
            "Reliable, fast, and measurable."
        ],
        "showcase": [
            "See it. Love it. Share it.",
            "Designed to be shown off.",
            "Beautifully yours."
        ],
        "custom": [
            "Made just for you.",
            "Your app, your way."
        ]
    ]

    /// Return copy for one template. Headline always echoes `base`.
    /// If `userSubtitle` is non-empty, it wins — we never overwrite explicit intent.
    static func copy(
        base: String,
        userSubtitle: String?,
        category: String,
        seed: String
    ) -> (headline: String, subtitle: String?) {
        if let userSubtitle, !userSubtitle.isEmpty {
            return (base, userSubtitle)
        }
        let bank = subtitleBank[category.lowercased()] ?? subtitleBank["custom"] ?? []
        guard !bank.isEmpty else { return (base, nil) }
        let index = abs(seed.hashValue) % bank.count
        return (base, bank[index])
    }
}
