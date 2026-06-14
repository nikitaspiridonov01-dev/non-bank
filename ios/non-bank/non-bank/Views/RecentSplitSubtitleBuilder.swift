import Foundation

/// Pure phrase builder for "Recently used" split shortcut subtitles.
///
/// The strings here are copied VERBATIM from
/// `CreateTransactionModal.modeSubtitleText` / `settleUpSubtitle` /
/// `subtitlePayerPrefix` / `truncatedSubtitleName` so a recent
/// shortcut reads identically to the live subtitle shown under the
/// amount once the same configuration is active. The only difference
/// is the inputs: the modal's builders read the live VM's
/// `display*` state, whereas these take explicit values resolved from
/// a `RecentSplitOption` + `FriendStore` at render time.
///
/// If the modal's phrasing ever changes, update both — they are
/// intentionally kept in lockstep.
enum RecentSplitSubtitleBuilder {
    /// Mirror of `CreateTransactionModal.subtitleNameMaxLength`.
    static let nameMaxLength = 10

    /// Mirror of `CreateTransactionModal.truncatedSubtitleName`.
    static func truncatedName(_ name: String) -> String {
        if name.count <= nameMaxLength { return name }
        let kept = name.prefix(nameMaxLength - 1)
        return "\(kept)…"
    }

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

        let payerPrefix = "You pay"   // recorded shortcuts always replay with the default payer = You
        let participantCount = (youIncluded ? 1 : 0) + friends.count
        let peopleWord = participantCount == 1 ? "person" : "people"

        switch mode {
        case .evenly:
            return "\(payerPrefix) and split evenly with \(participantCount) \(peopleWord)"
        case .byAmount:
            return "\(payerPrefix) and split by amount with \(participantCount) \(peopleWord)"
        case .byItems:
            return "\(payerPrefix) and split the receipt with \(participantCount) \(peopleWord)"
        case .settleUp:
            return settleUpSubtitle(payer: settleUpPayer, recipient: settleUpRecipient)
        }
    }

    /// Mirror of `CreateTransactionModal.settleUpSubtitle`, expressed
    /// directly from the directional payer/recipient pair rather than
    /// re-deriving it from a payers array.
    ///   - "You pay for {recipient}"
    ///   - "{payer} pays for you"
    ///   - "{payer} pays for {recipient}"
    private static func settleUpSubtitle(payer: Person?, recipient: Person?) -> String {
        guard let payer, let recipient else { return "Settle up" }
        if payer.id == "me" {
            return "You pay for \(truncatedName(recipient.name))"
        }
        if recipient.id == "me" {
            return "\(truncatedName(payer.name)) pays for you"
        }
        return "\(truncatedName(payer.name)) pays for \(truncatedName(recipient.name))"
    }
}
