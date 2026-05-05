import Foundation

/// Decides whether a receipt OCR line is a *product* line or a non-product
/// artifact (totals, taxes, payment, change, etc.). Used both as a pre-filter
/// before the regex line parser and as a post-filter on Foundation Models
/// output so accuracy stays the same regardless of which path produced the
/// items.
///
/// ## Languages covered
/// EN, RU, DE, FR, ES, IT, PT, SR (Latin), PL — keywords and common OCR
/// transliterations of Cyrillic words. Match is case-insensitive and uses
/// Unicode word boundaries (`\b`), so `card` won't match inside `cardamom`.
struct ReceiptLineFilter {

    enum Verdict: Equatable {
        case keep                  // probably an item line
        case skipNonProduct        // tax / subtotal / payment / change / etc.
        case anchorTotal           // the grand-total line — strong section anchor
        case discount              // a discount line — kept as a negative item
    }

    /// Classifies a single line of receipt text. Order of checks matters:
    /// 1. **Discount** runs first — a line like "Скидка 10%" must NOT fall
    ///    through to nonProduct (which would silently drop it) and must NOT
    ///    be promoted to anchor by an embedded `total` token (e.g., German
    ///    "Rabatt total" hypothetically — never seen, but cheap insurance).
    /// 2. **Non-product** runs before anchor so `Sub-total`, `Subtotale`,
    ///    etc. don't get promoted to anchor by the embedded `total` token.
    /// 3. **Pattern-based** (dates, masked cards, phones) runs after the
    ///    keyword regexes since it's a stricter check.
    /// 4. **Anchor** runs last — only fires when nothing more specific did.
    static func classify(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipNonProduct }

        if Self.discountRegex.matches(in: trimmed) {
            return .discount
        }
        if Self.nonProductRegex.matches(in: trimmed) {
            return .skipNonProduct
        }
        if Self.matchesNonProductPattern(trimmed) {
            return .skipNonProduct
        }
        if Self.anchorTotalRegex.matches(in: trimmed) {
            return .anchorTotal
        }
        return .keep
    }

    // MARK: - Anchor (grand total)

    /// Words that *only* mark the grand-total line. Kept narrow so we don't
    /// accidentally skip an item that contains a sub-total-like word. The
    /// bare word `total` is intentionally here (not in `nonProductWords`)
    /// because it's the strongest grand-total signal across languages.
    ///
    /// Round C-2 added Serbian Cyrillic forms — fiscal receipts in Serbia
    /// print `Укупан износ` (= "total amount") in Cyrillic, and the previous
    /// list only had Latin `ukupno`/`ukupan iznos`.
    private static let anchorTotalWords: [String] = [
        "total", "grand total", "amount due", "total due", "balance due",
        "итого", "всего", "к оплате",
        "gesamt", "endsumme", "zu zahlen",
        "à payer",
        "totale",
        "ukupno", "ukupan iznos", "za naplatu",
        "укупно", "укупан износ", "за наплату",
        "razem", "do zapłaty", "do zaplaty",
        "totaal"
    ]

    private static let anchorTotalRegex = WordRegex(words: anchorTotalWords)

    // MARK: - Non-product keywords

    /// Words that, when present anywhere in the line, mean the line is admin
    /// / footer / payment noise. The bare word `total` is intentionally NOT
    /// here — it's reserved for `anchorTotalWords` so a one-off `Total` line
    /// is treated as the body terminator, not as a skipped non-product.
    private static let nonProductWords: [String] = [
        // Subtotals
        "subtotal", "sub-total", "sub total", "sous-total", "subtotale",
        "промежуточная", "промежуточный итог", "tussentotaal", "zwischensumme",
        "międzysuma", "miedzysuma",

        // Taxes
        "vat", "tax", "taxes", "tva", "iva", "mwst", "ust", "umsatzsteuer",
        "ндс", "nds", "налог", "nalog", "podatek", "pdv", "porez",
        "impôt", "impot", "impuesto",

        // Payment methods
        "cash", "credit", "debit", "card", "visa", "mastercard", "amex",
        "наличные", "карта", "картой",
        "gotovina", "kartica",
        "kreditkarte", "ec-karte", "bargeld",
        "espèces", "carte bancaire",
        "efectivo", "tarjeta",
        "dinheiro", "cartão", "cartao",
        "contanti",
        "gotówka", "gotowka",
        "apple pay", "google pay",

        // Change / refund
        "change", "сдача", "rückgeld", "ruckgeld", "rendu",
        "monnaie", "vuelto", "troco", "kusur", "reszta", "resto",

        // NOTE: Discount-related keywords (`discount`, `скидка`, `rabat`,
        // etc.) USED TO live here but were silently dropped. They moved to
        // `discountWords` below so a `Скидка -5,00` row survives as a
        // negative item in the parsed receipt instead of vanishing.

        // Tips / service
        "tip", "tips", "чаевые", "trinkgeld", "pourboire",
        "propina", "gorjeta", "mancia", "napojnica", "napiwek",
        "service charge", "gratuity", "obsługa", "obsluga",

        // Loyalty / points
        "loyalty", "points", "бонусы", "punti", "pontos",
        "puntos", "punkty",

        // Receipt / admin / contact
        "receipt", "чек", "rachunek", "paragon", "rechnung",
        "ricevuta", "recibo",
        "thank you", "спасибо", "danke", "merci", "gracias",
        "obrigado", "grazie", "hvala", "dziękuję", "dziekuje",
        "operator", "cashier", "касса", "kassa", "kasjer",
        "phone", "tel.", "tel:", "телефон", "address", "адрес",
        "tax id", "инн", "vat id", "nip", "regon",
        "void", "refund", "возврат",
        "balance", "баланс", "saldo",

        // Round C-2 — staff & layout labels (English first, then EU)
        "waiter", "server", "host", "hostess",
        "table", "guest", "ticket", "tab",
        "open", "opened", "closed",  // "Open: 12:34" admin lines
        "order no", "order number",
        "официант", "стол",          // Russian admin labels
        "kelner",                    // Polish waiter
        "kellner", "tisch",          // German waiter / table
        "serveur", "serveuse",       // French waiter
        "camarero", "mesero", "mesa",  // Spanish waiter / table
        "garçom", "garcom",          // Portuguese waiter
        "cameriere", "tavolo",       // Italian waiter / table

        // Round C-2 — Russian / Serbian Cyrillic admin labels
        // (Common on Wolt/Yandex order summaries.)
        "статус", "позиции", "доставка"
    ]

    /// Slavic stems with letter-suffix wildcards. Receipt printers use case
    /// forms freely (`касир`, `касира`, `касиру`, `касиром`), so plain
    /// word matching misses ~half of them. The stem `касир` plus `\p{L}*`
    /// catches every form.
    ///
    /// Cross-language risk: `артикл` could match Italian `articolo` if the
    /// stem were `артикол`. Restricted to Cyrillic-only stems where the
    /// Latin equivalent is rare on receipts.
    private static let nonProductCyrillicStems: [String] = [
        "касир",   // Serbian Cyrillic: cashier (касира, касиру, касиром)
        "конобар", // Serbian Cyrillic: waiter
        "пореск",  // Serbian Cyrillic: tax-related (порески, порескa)
        "порез",   // Serbian Cyrillic: tax (пореза, порезу, порезом, порезе, порези)
        "промет",  // Serbian Cyrillic: turnover header
        "артикл",  // Serbian Cyrillic: articles (артикли, артикала, артиклима)
        "назив",   // Serbian Cyrillic: name header
        "ознак",   // Serbian Cyrillic: designation (ознака, ознаку, ознаком)
        "стопа",   // Serbian Cyrillic: rate (стопе, стопу, стопом)
        "броач",   // Serbian Cyrillic: counter
        "рачун",   // Serbian Cyrillic: receipt / account
        "пфр"      // Serbian Cyrillic: fiscal protocol abbreviation
    ]

    private static let nonProductRegex = WordRegex(
        words: nonProductWords,
        stems: nonProductCyrillicStems
    )

    // MARK: - Discount keywords

    /// Words that mark a discount / promo / rebate line. These rows are
    /// kept as items (with negative line totals) rather than dropped, so
    /// the receipt's grand total still balances when prices on individual
    /// items are quoted at full retail and the discount is on its own row.
    ///
    /// We also include the lowercase `tip` synonyms here when... actually
    /// we don't — tips legitimately add to the total and are still routed
    /// to `nonProductWords` (a tip is conceptually a payment, not a price
    /// reduction).
    private static let discountWords: [String] = [
        // English
        "discount", "promo", "promotion", "rebate", "off",
        "voucher", "coupon", "loyalty discount",
        // Russian
        "скидка", "скидки", "скидку", "акция", "промо",
        // German
        "rabatt", "nachlass",
        // French
        "remise", "réduction", "reduction", "ristourne",
        // Spanish
        "descuento", "rebaja",
        // Italian
        "sconto", "ribasso",
        // Portuguese
        "desconto",
        // Polish
        "rabat", "zniżka", "znizka",
        // Serbian (Latin) / Croatian
        "popust", "akcija"
    ]

    private static let discountRegex = WordRegex(words: discountWords)

    // MARK: - Non-product patterns

    /// Pattern-based rules for lines that are clearly not items even when
    /// they don't contain a stop-word — masked card numbers, phone numbers,
    /// long tax IDs, dates.
    ///
    /// Round C-2 added two more date patterns. The previous "whole-line
    /// date" required the date to occupy the entire line; in real OCR a
    /// timestamp is often glued to other tokens (`Open: 11.04.2026 13:08
    /// Order No. 261505`) and slipped through. The two new patterns match
    /// dates *anywhere* — both numeric (`11.04.2026`) and textual
    /// (`27 АПРЕЛЯ 2026`).
    private static let nonProductPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            // Masked card: **** 1234, XX 1234, "ending in 1234"
            #"\*{2,}\s?\d{2,4}"#,
            #"\bx{2,}\s?\d{2,4}\b"#,
            #"ending\s+in\s+\d{2,4}"#,
            // International phone numbers — 9+ chars made of digits, spaces,
            // hyphens or parens, optionally preceded by `+`. Catches both
            // `+1 (555) 123-4567` and `+7 916 123 45 67`.
            #"\+?[\d\s\-\(\)]{9,}"#,
            // Pure date-time lines (no letters except am/pm)
            #"^\s*\d{1,2}[./\-]\d{1,2}[./\-]\d{2,4}(\s+\d{1,2}:\d{2}(\s*[ap]m)?)?\s*$"#,
            // Numeric date anywhere on the line: 27.04.2026 / 11/04/26 /
            // 2026-04-11. Specifically requires day+sep+month+sep+year so
            // we don't hit a stray `1.5` (price) or version string.
            #"\b\d{1,2}[./\-]\d{1,2}[./\-]\d{2,4}\b"#,
            #"\b\d{4}[./\-]\d{1,2}[./\-]\d{1,2}\b"#,
            // Textual date with month name: "27 АПРЕЛЯ 2026", "27 Apr 2026".
            // Day + space + 3+ letters + space + 4-digit year (1900–2099).
            #"\b\d{1,2}\s+\p{L}{3,}\s+(19|20)\d{2}\b"#,
            // URL / email
            #"\bhttps?://"#,
            #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    private static func matchesNonProductPattern(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for re in nonProductPatterns {
            if re.firstMatch(in: text, options: [], range: range) != nil { return true }
        }
        return false
    }

    // MARK: - WordRegex helper

    /// Compiled multi-keyword Unicode-aware word-boundary regex. We build one
    /// per category and keep them as static lets so each call is just a
    /// regex match — cheap enough for a 100-line receipt.
    ///
    /// Two flavours of alternation:
    /// - **words**: literal tokens, matched at word boundaries. Used for
    ///   English/German/French/etc. where suffixes don't change the stem.
    /// - **stems**: stem + `\p{L}*` to absorb Slavic case suffixes. So
    ///   stem `касир` matches `касир`, `касира`, `касиру`, `касиром` — all
    ///   valid Serbian Cyrillic forms of "cashier" — without enumerating
    ///   each one by hand.
    private struct WordRegex {
        let regex: NSRegularExpression?

        init(words: [String], stems: [String] = []) {
            var alternatives: [String] = words.map {
                // `escapedPattern` covers special regex chars; we lowercase
                // here so the match itself is plain literal text.
                NSRegularExpression.escapedPattern(for: $0.lowercased())
            }
            for stem in stems {
                let escaped = NSRegularExpression.escapedPattern(for: stem.lowercased())
                // `\p{L}*` greedy lets the engine consume any case suffix
                // before the trailing `\b` anchor closes the word.
                alternatives.append(escaped + #"\p{L}*"#)
            }
            // `\b` is Unicode-aware in NSRegularExpression so it works for
            // Cyrillic and Latin alike. We lowercase the input before
            // matching, so `[case-insensitive]` is just a safety belt.
            let pattern = #"\b("# + alternatives.joined(separator: "|") + #")\b"#
            self.regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        func matches(in text: String) -> Bool {
            guard let regex else { return false }
            let lower = text.lowercased()
            let range = NSRange(lower.startIndex..., in: lower)
            return regex.firstMatch(in: lower, options: [], range: range) != nil
        }
    }
}
