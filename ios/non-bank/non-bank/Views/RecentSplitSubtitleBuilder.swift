import Foundation

/// Pure phrase builder for "Recently used" split shortcut subtitles.
///
/// Unlike the live subtitle under the amount (which reads "You pay and split
/// evenly with N people"), a recent shortcut names the actual participants so
/// you can tell two recents apart at a glance — "Between you and Alex" vs
/// "Between you, Sam and 2 more people". `.settleUp` keeps its directional
/// phrasing ("{payer} pays for you"). Inputs are resolved live from a
/// `RecentSplitOption` + `FriendStore` at render time. Names are NOT
/// truncated — the row subtitle wraps instead of clipping.
enum RecentSplitSubtitleBuilder {

    /// A participant in a recent option, resolved live.
    struct Person {
        let id: String        // "me" or Friend.id
        let name: String      // "You" or Friend.name
    }

    /// Build the subtitle for a recent shortcut.
    ///
    /// - `mode`: the recorded split mode.
    /// - `friends`: resolved selected friends (excludes "me"), in
    ///   recorded order.
    /// - `youIncluded`: whether the user is in the split.
    /// - For `.settleUp`, `settleUpPayer` / `settleUpRecipient` carry
    ///   the directional pair (resolved to display names).
    static func subtitle(
        mode: SplitMode,
        friends: [Person],
        youIncluded: Bool,
        settleUpPayer: Person?,
        settleUpRecipient: Person?
    ) -> String {
        if mode == .settleUp {
            return settleUpSubtitle(payer: settleUpPayer, recipient: settleUpRecipient)
        }
        return betweenPhrase(friends: friends, youIncluded: youIncluded)
    }

    /// "Between …" participant summary. "You" leads when included; an
    /// overflow past three names collapses to "N more people".
    ///   - you + 1 friend   → "Between you and Alex"
    ///   - 2 friends        → "Between Alex and Sam"
    ///   - you + 2 friends  → "Between you, Alex and Sam"
    ///   - you + 3+ friends → "Between you, Alex and 2 more people"
    private static func betweenPhrase(friends: [Person], youIncluded: Bool) -> String {
        var names: [String] = []
        if youIncluded { names.append("you") }
        names += friends.map(\.name)
        let list = naturalList(names)
        return list.isEmpty ? "Just you" : "Between \(list)"
    }

    /// Grammatical join with a head-and-tail overflow:
    /// `[a]`→"a", `[a,b]`→"a and b", `[a,b,c]`→"a, b and c",
    /// `[a,b,c,d,…]`→"a, b and N more people".
    private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        case 3: return "\(items[0]), \(items[1]) and \(items[2])"
        default:
            let remaining = items.count - 2
            let noun = remaining == 1 ? "person" : "people"
            return "\(items[0]), \(items[1]) and \(remaining) more \(noun)"
        }
    }

    /// Directional settle-up phrasing from the payer/recipient pair:
    ///   - "You pay for {recipient}"
    ///   - "{payer} pays for you"
    ///   - "{payer} pays for {recipient}"
    private static func settleUpSubtitle(payer: Person?, recipient: Person?) -> String {
        guard let payer, let recipient else { return "Settle up" }
        if payer.id == "me" {
            return "You pay for \(recipient.name)"
        }
        if recipient.id == "me" {
            return "\(payer.name) pays for you"
        }
        return "\(payer.name) pays for \(recipient.name)"
    }
}
