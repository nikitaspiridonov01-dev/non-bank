import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Transaction Share Item Source
//
// Provides differentiated share content per `UIActivity.ActivityType`:
//
//   • Plain-share destinations (AirDrop, Copy, Save to Files, Add to
//     Reading List, etc.) → just the URL. The receiving app sees a
//     bare link, exactly like before — no formatting clutter.
//
//   • Messenger / mail / third-party share destinations → human-
//     readable summary text **with** the URL appended. iMessage,
//     Telegram, WhatsApp etc. auto-detect the URL inside the text and
//     still render their rich-preview card from the Worker page's
//     OpenGraph meta. Recipient sees both: a glance at what's being
//     shared (title, items list, total, recurring info) plus the
//     interactive link card.
//
// This is the bridge that lets us keep the URL itself short (no items
// in `?p=…`) while still delivering items as readable text in chats.

final class TransactionShareItemSource: NSObject, UIActivityItemSource {

    /// The `nonbank://` (or webBackend) URL the sharer intends to send.
    /// Always returned verbatim for plain-share destinations.
    private let url: URL

    /// Pre-built human-readable summary. Used for chat / mail / social
    /// destinations as `summary + "\n" + url`. Built once at init so
    /// `itemForActivityType` is cheap and side-effect-free (the docs
    /// stress this method runs on background threads).
    private let summaryText: String

    init(url: URL, summaryText: String) {
        self.url = url
        self.summaryText = summaryText
    }

    // MARK: UIActivityItemSource

    /// Placeholder returned synchronously while the share sheet builds.
    /// Always the URL so iOS can compute previews / decide layout
    /// before our `itemForActivityType:` returns the real payload.
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    /// Real item for a given activity. Branches on the activity type:
    /// destinations that benefit from prose context get the summary +
    /// URL, the rest get the URL alone.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        if shouldUsePlainURL(for: activityType) {
            return url
        }
        return "\(summaryText)\n\n\(url.absoluteString)"
    }

    /// Email subject — the activity uses this when the destination has
    /// a separate subject field (Mail, some messaging apps with subject
    /// metadata). Fall back to the title line of the summary.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        let firstLine = summaryText.split(whereSeparator: \.isNewline).first.map(String.init)
        return firstLine ?? "Shared transaction"
    }

    /// UTI of the actual returned item, declared to the activity's
    /// extension. Critical for messengers like Telegram: their share
    /// extension loads content by UTI ("public.url" → `loadItem(for:
    /// .url)`), so if we hand them a String but declare URL, Telegram
    /// silently drops the text and uses a stale URL or nothing. By
    /// returning `public.plain-text` for the messenger branch the
    /// extension knows to load the content as text — and `iMessage` /
    /// `Telegram` / `WhatsApp` then treat it as a message body, with
    /// any URL substring auto-recognised and previewed via OpenGraph.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        if shouldUsePlainURL(for: activityType) {
            return UTType.url.identifier
        }
        return UTType.plainText.identifier
    }

    // MARK: Activity classification

    /// True when the activity type should receive ONLY the URL (no
    /// prose). The list mirrors share-sheet destinations where text
    /// prefix would either be ignored (AirDrop just sends the URL),
    /// dropped (clipboard / Files), or look out of place (notes,
    /// reading list).
    private func shouldUsePlainURL(for type: UIActivity.ActivityType?) -> Bool {
        guard let type = type else {
            // Unknown activity (third-party app that didn't declare a
            // type). Default to the rich text+URL combo — most
            // third-party apps treat shared content as message bodies.
            return false
        }
        switch type {
        case .airDrop,
             .copyToPasteboard,
             .saveToCameraRoll,
             .assignToContact,
             .addToReadingList,
             .openInIBooks,
             .print:
            return true
        default:
            return false
        }
    }
}

// MARK: - Summary text builder

/// Formats a human-readable share summary for messenger / mail
/// destinations. Pure function — caller resolves friend names,
/// receipt items, and recurring info up-front from the relevant
/// stores. Keeps `TransactionShareItemSource` free of store
/// dependencies (it only knows about the strings it gets handed).
enum TransactionShareSummary {

    /// All the moving parts the formatter needs. Resolved at the
    /// share-tap site so the formatter itself stays push-only.
    struct Context {
        let title: String
        let categoryEmoji: String
        let totalAmount: Double
        let currency: String
        let isExpense: Bool
        let date: Date
        /// Sharer's display name when set. The opening line uses it
        /// as the personal "Nikita shared X with you" greeting.
        let sharerName: String?
        /// Receipt items, if the transaction has them. Rendered as a
        /// bulleted list under the total. Items are NOT shipped in the
        /// URL (would balloon the link); this is the only path by
        /// which the recipient sees them at all.
        let items: [ReceiptItem]
        /// Recurring rule, if the transaction recurs. Rendered as a
        /// short footer line ("Repeats: Yearly on Jan 15 at 09:00").
        let recurring: RepeatInterval?
    }

    /// Build the summary string. Multi-line, plain text. The URL is
    /// appended by `TransactionShareItemSource` separately so the
    /// formatter doesn't need to know it.
    static func build(_ ctx: Context) -> String {
        var lines: [String] = []

        // Header — friendly greeting if we have a sharer name, plain
        // title fallback otherwise (covers freshly-installed users
        // who haven't set their profile name yet).
        let titleLine = "\(ctx.categoryEmoji) \(ctx.title)"
        if let name = ctx.sharerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            lines.append("\(name) shared this with you:")
            lines.append("")
            lines.append(titleLine)
        } else {
            lines.append(titleLine)
        }

        // Total + item count line. Sign on `−` for expenses to match
        // the in-app balance vocabulary.
        let signPrefix = ctx.isExpense ? "−" : "+"
        let amountStr = formatAmount(ctx.totalAmount, currency: ctx.currency)
        let itemsCount = ctx.items.count
        let countSuffix: String = {
            if itemsCount == 0 { return "" }
            return " · \(itemsCount) \(itemsCount == 1 ? "item" : "items")"
        }()
        lines.append("\(signPrefix)\(amountStr)\(countSuffix)")

        // Items list — only when present. Bulleted. Falls back to
        // `total` for the line amount, with `qty × price` displayed
        // in the name when the item has a non-trivial quantity.
        if !ctx.items.isEmpty {
            lines.append("")
            for item in ctx.items {
                lines.append("• \(formatItem(item, currency: ctx.currency))")
            }
        }

        // Recurring footer — keeps the chat preview readable at a
        // glance ("oh, this is the rent, runs monthly").
        if let interval = ctx.recurring {
            lines.append("")
            lines.append("Repeats: \(interval.displayLabel)")
        }

        // Date. Same short format the in-app row uses.
        lines.append("")
        lines.append("Counted: \(formatDate(ctx.date))")

        // Hint near the URL — `TransactionShareItemSource` appends the
        // URL right after this text, so this line acts as the inline
        // CTA. Plain "Open in non-bank:" mirrors the web preview's
        // primary CTA and works whether the recipient has the app
        // (deep-link opens it) or doesn't (Worker's `/share` page
        // renders the same details).
        lines.append("")
        lines.append("Open in non-bank app:")

        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    private static func formatAmount(_ value: Double, currency: String) -> String {
        let intPart = NumberFormatting.integerPart(value)
        let decimal = NumberFormatting.decimalPartIfAny(value)
        return "\(intPart)\(decimal) \(currency)"
    }

    private static func formatItem(_ item: ReceiptItem, currency: String) -> String {
        let name: String
        if let qty = item.quantity, qty > 1, let price = item.price {
            name = "\(item.name) (\(ReceiptItem.formatQuantity(qty)) × \(ReceiptItem.formatAmount(price)))"
        } else {
            name = item.name
        }
        let lineAmount = formatAmount(item.lineTotal, currency: currency)
        return "\(name) — \(lineAmount)"
    }

    private static func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today at' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday at' HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "'Tomorrow at' HH:mm"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }
}
