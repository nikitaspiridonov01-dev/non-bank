import Foundation

/// Generates deterministic-looking but random IDs in the format `adjective-noun-4digits`.
/// Example: "amber-lynx-7K2D"
enum FriendIDGenerator {

    // Crockford Base32 alphabet (excludes I, L, O, U)
    private static let base32Chars: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let adjectives = [
        "amber", "azure", "bold", "brave", "bright", "calm", "clever", "cold",
        "cool", "coral", "crimson", "crystal", "dark", "deep", "dusty", "eager",
        "fair", "fierce", "gentle", "golden", "grand", "green", "happy", "honest",
        "icy", "iron", "jade", "keen", "kind", "lemon", "light", "lone",
        "lucky", "lunar", "marble", "mellow", "misty", "neon", "noble", "olive",
        "pale", "pearl", "pine", "proud", "pure", "quick", "quiet", "rapid",
        "rare", "rough", "royal", "ruby", "rust", "sage", "sharp", "shy",
        "silent", "silver", "sleek", "slim", "soft", "solar", "solid", "steel",
        "stone", "storm", "swift", "teal", "tender", "tiny", "true", "vast",
        "velvet", "vivid", "warm", "wild", "wise", "young", "zen", "zinc"
    ]

    private static let nouns = [
        "ape", "bat", "bear", "bee", "bird", "boar", "buck", "bull",
        "cat", "colt", "crab", "crow", "deer", "dove", "duck", "eagle",
        "elk", "emu", "fawn", "finch", "fish", "fox", "frog", "goat",
        "goose", "hare", "hawk", "hog", "ibis", "jay", "kite", "lark",
        "lion", "lynx", "mink", "mole", "moth", "mouse", "newt", "osprey",
        "otter", "owl", "ox", "panda", "puma", "quail", "ram", "raven",
        "robin", "seal", "shark", "shrew", "sloth", "slug", "snail", "snake",
        "squid", "stag", "stork", "swan", "tiger", "toad", "trout", "viper",
        "vole", "wasp", "whale", "wolf", "wren", "yak", "zebra", "crane"
    ]

    /// Generate a new unique friend ID.
    static func generate() -> String {
        let adj = adjectives.randomElement()!
        let noun = nouns.randomElement()!
        let code = String((0..<4).map { _ in base32Chars.randomElement()! })
        return "\(adj)-\(noun)-\(code)"
    }
}
