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
        case skipNonProduct        // subtotal / payment / change / loyalty / admin / tax
        case anchorTotal           // the grand-total line — strong section anchor
        case discount              // a discount line — kept as a negative item
        case fee                   // a service / delivery / handling fee line
    }

    /// Classifies a single line of receipt text. Order of checks matters:
    /// 1. **Discount** runs first so a line like "Total discount: -5,00"
    ///    doesn't get promoted to `.anchorTotal` by the embedded `total`
    ///    token.
    /// 2. **Non-product keywords** runs next so admin compound stop-words
    ///    (`tax id`, `vat id`, etc.), AND tax/VAT/НДС lines, all skip
    ///    cleanly. Tax was formerly its own `.tax` verdict that got
    ///    distributed across split participants; it's now classified as
    ///    skip because tax is store-side metadata (already baked into
    ///    the grand total), not a buyer-paid charge the user wants to
    ///    track. Buyer-paid duties / fees stay as `.fee`.
    /// 3. **Fee** then routes to the keep-with-kind `.fee` verdict.
    ///    Tips are NOT auto-classified — a tip / gratuity / service-charge
    ///    line falls through to `.keep` (a regular item) unless it also
    ///    matches a fee keyword (e.g. "service charge"), in which case it
    ///    becomes `.fee`. Tips can only be tagged manually in the editor
    ///    (which sets `ReceiptItem.forcedKind = .tip`).
    /// 4. **Pattern-based** (dates, masked cards, phones) runs after the
    ///    keyword regexes since it's a stricter check.
    /// 5. **Anchor** runs last — only fires when nothing more specific did.
    static func classify(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipNonProduct }

        if Self.discountRegex.matches(in: trimmed) {
            return .discount
        }
        if Self.nonProductRegex.matches(in: trimmed) {
            return .skipNonProduct
        }
        if Self.feeRegex.matches(in: trimmed) {
            return .fee
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
    ///
    /// NOTE: Fee keywords USED TO live here alongside tax. Fees moved to the
    /// dedicated `feeWords` list below so the "by items" split mode can keep
    /// those rows as semantically tagged `.fee` items and distribute them
    /// proportionally to each participant's item subtotal — rather than
    /// dropping them silently the way a true admin / payment line is dropped.
    /// Tips are NOT classified at all anymore: a tip / gratuity line falls
    /// through to `.keep` (a regular item) unless it also matches `feeWords`
    /// (e.g. "service charge"). Manual tips are tagged in the editor via
    /// `ReceiptItem.forcedKind = .tip`. Tax keywords remain in this list
    /// (skipped as store-side metadata).
    private static let nonProductWords: [String] = [
        // Subtotals
        "subtotal", "sub-total", "sub total", "sous-total", "subtotale",
        "промежуточная", "промежуточный итог", "tussentotaal", "zwischensumme",
        "międzysuma", "miedzysuma",

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

        // Loyalty / points
        "loyalty", "points", "бонусы", "punti", "pontos",
        "puntos", "punkty",

        // Receipt / admin / contact
        "receipt", "чек", "rachunek", "paragon", "rechnung",
        "ricevuta", "recibo",
        "thank you", "спасибо", "danke", "merci", "gracias",
        "obrigado", "grazie", "hvala", "dziękuję", "dziekuje",
        "operator", "cashier", "касса", "kassa", "kasjer",
        // Tel/phone labels — all require punctuation suffix so the bare
        // word doesn't false-match real items. `"Phone:"` / `"tel:"` /
        // `"tel."` cover the printed formats; lines like "Phone charger"
        // or "Hands-free phone" fall through to the keep verdict. Loose
        // bare "Phone 555-1234" lines are still caught by the pattern-
        // based phone-number regex below.
        "phone:", "tel.", "tel:", "телефон", "address", "адрес",
        "tax id", "инн", "vat id", "nip", "regon",
        "void", "refund", "возврат",
        "balance", "баланс", "saldo",

        // Tax / VAT / sales-tax — store-side metadata (already baked
        // into the grand total), not a buyer charge to track. Skipped
        // so the line never enters the items list. Buyer-paid duties
        // (city tax, tourist tax, …) are NOT here; if a receipt prints
        // those with an explicit qualifier, the `.fee` list handles
        // them via the same compound-word pattern as `cover charge`.
        "vat", "tax", "taxes", "tva", "iva", "mwst", "ust", "umsatzsteuer",
        "ндс", "nds", "налог", "nalog", "podatek", "pdv", "porez",
        "impôt", "impot", "impuesto",

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
        "промет",  // Serbian Cyrillic: turnover header
        "артикл",  // Serbian Cyrillic: articles (артикли, артикала, артиклима)
        "назив",   // Serbian Cyrillic: name header
        "ознак",   // Serbian Cyrillic: designation (ознака, ознаку, ознаком)
        "стопа",   // Serbian Cyrillic: rate (стопе, стопу, стопом)
        "броач",   // Serbian Cyrillic: counter
        "рачун",   // Serbian Cyrillic: receipt / account
        "пфр",     // Serbian Cyrillic: fiscal protocol abbreviation
        // Tax stems — Serbian Cyrillic case-form catch-all. See the
        // "store-side tax" rationale on `nonProductWords`.
        "пореск",  // tax-related (порески, пореска)
        "порез"    // tax (пореза, порезу, порезом, порезе, порези)
    ]

    private static let nonProductRegex = WordRegex(
        words: nonProductWords,
        stems: nonProductCyrillicStems
    )

    // MARK: - Fee keywords
    //
    // NOTE: Tips are intentionally NOT auto-classified. A tip / gratuity
    // line is treated as a regular item (`.keep`) unless it also matches a
    // fee keyword below (e.g. "service charge", which is in `feeWords`), in
    // which case it becomes `.fee`. Manual tips are tagged in the editor
    // via `ReceiptItem.forcedKind = .tip`, which bypasses this classifier.

    /// Words that identify a fee / surcharge line (delivery, booking,
    /// handling, processing, convenience, etc.). Kept as `.fee`-kinded
    /// rows so the "by items" split distributes them proportionally to
    /// each participant's item subtotal.
    ///
    /// Generic words like `fee` and `frais` match alone; compound forms
    /// like `service fee`, `delivery fee` will hit the bare `fee` token
    /// without needing every variant listed. The `... charge` family
    /// (cover/booking/extra/minimum/svc) is enumerated explicitly
    /// because bare `charge` is too risky a token to add globally —
    /// real items occasionally contain it ("Charge cable", "Charging
    /// pad"), and false-positives on those would silently demote
    /// product lines into the proportional-distribution bucket.
    private static let feeWords: [String] = [
        // English — bare tokens (match any line containing them)
        "fee", "fees", "surcharge",
        // English — compound "X charge" phrases. Each requires the
        // qualifier so we don't over-match on items whose names
        // happen to contain "charge".
        "service charge", "service fee", "delivery fee", "handling fee",
        "booking fee", "processing fee", "convenience fee",
        "cover charge", "booking charge", "extra charge", "minimum charge",
        // Common OCR / receipt abbreviations
        "svc charge", "svc fee", "svc. charge", "svc. fee",
        // Russian
        "сбор", "сервисный сбор", "комиссия", "доставка",
        // German
        "gebühr", "gebuehr", "servicegebühr", "lieferung",
        // French
        "frais", "frais de service", "frais de livraison", "supplément",
        // Spanish
        "tarifa de servicio", "cargo por servicio", "envío", "envio",
        // Italian
        "supplemento", "coperto", "consegna",
        // Portuguese
        "taxa de serviço", "taxa de entrega",
        // Polish
        "opłata", "oplata", "dostawa",
        // Serbian (Latin) / Croatian. `servis` standalone catches the
        // common restaurant shorthand for service charge (the longer
        // `servisna naknada` is already covered transitively via the
        // bare `naknada` token below). Plain `\b…\b` word boundaries
        // ensure it doesn't accidentally match item-name compounds
        // like `servisni dodatak` or `servisiranje`.
        "servis", "naknada", "dostava"
    ]

    /// Cyrillic stems for fee detection. `обслуживан` covers all case
    /// forms of "service" on Russian receipts (обслуживание, обслуживания,
    /// обслуживанию, etc.). `услуг` and `сервис` catch the standalone
    /// Serbian/Russian Cyrillic service-charge labels that some
    /// restaurants print (`Услуга`, `Сервис`, `Услуге`) — without the
    /// stems they fell through every list and ended up as `.item`,
    /// which is the bug this paragraph commemorates. Some legitimate
    /// product names on service-business receipts may now be tagged
    /// as `.fee` (e.g. `Услуга стрижки` on a salon receipt); the
    /// trade-off is intentional — false-positive .fee on a salon row
    /// is a wrong icon the user can fix in the editor, whereas
    /// false-negative on a restaurant service charge silently inflates
    /// every participant's "by items" share.
    private static let feeCyrillicStems: [String] = [
        "обслуживан",
        "услуг",
        "сервис"
    ]

    private static let feeRegex = WordRegex(words: feeWords, stems: feeCyrillicStems)

    // MARK: - Discount keywords

    /// Words that mark a discount / promo / rebate line. These rows are
    /// kept as items (with negative line totals) rather than dropped, so
    /// the receipt's grand total still balances when prices on individual
    /// items are quoted at full retail and the discount is on its own row.
    ///
    /// ## Sign beats name
    /// A discount is fundamentally a line that REDUCES the total. The name
    /// is only a WEAK, ambiguous signal — the strong signal is a negative
    /// printed amount. Both `ReceiptItem.Kind.classify` and
    /// `HybridReceiptParser.postProcess` therefore only honour a name-based
    /// `.discount` verdict when the line's amount is NOT positive; a
    /// positively-priced line stays a regular item even if it lands here.
    /// Because of that guard, marketing words that double as PRODUCT names
    /// must be kept OUT of this list — otherwise a sign-less or zero-amount
    /// line could still be wrongly deducted, and the on-device icon would
    /// be wrong. Removed for that reason: `deal` (meal/combo deals are
    /// positively-priced products), bare `off` / `save` / `saved` (far too
    /// generic — they appear in ordinary item names; the explicit `% off`
    /// markers below are kept). Keep only unambiguous discount/rebate/
    /// markdown markers.
    private static let discountWords: [String] = [
        // English
        "discount", "promo", "promotion", "rebate",
        "voucher", "coupon", "loyalty discount",
        "savings", "markdown", "marked down",
        "clearance", "% off", "%off",
        // Russian
        "скидка", "скидки", "скидку", "акция", "промо",
        "скидочка", "распродажа",
        // German
        "rabatt", "nachlass", "ermäßigung", "preisnachlass",
        // French
        "remise", "réduction", "reduction", "ristourne", "promotion",
        // Spanish
        "descuento", "rebaja", "oferta",
        // Italian
        "sconto", "ribasso", "saldo",
        // Portuguese
        "desconto",
        // Polish
        "rabat", "zniżka", "znizka", "obniżka", "obnizka",
        // Serbian (Latin) / Croatian
        "popust", "akcija", "sniženje", "snizenje"
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
            // International phone numbers — ≥9 actual DIGITS, optionally
            // grouped by spaces / hyphens / parens and preceded by `+`.
            // Counting digits (not characters) is deliberate: the old
            // `[\d\s\-\(\)]{9,}` matched a 7-digit fiscal product code glued
            // to a tax marker — "…/KOM/9004375 (Б)" contains the 9-char run
            // "9004375 (" — and dropped the real grocery item as a "phone".
            // `+1 (555) 123-4567` and `+7 916 123 45 67` (11 digits) still
            // match; a 7-digit code does not.
            #"\+?\d(?:[\s\-\(\)]*\d){8,}"#,
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
                let escaped = NSRegularExpression.escapedPattern(for: $0.lowercased())
                // Multi-word phrases need flexible separator matching —
                // OCR routinely emits double-space, tab, or hyphen
                // between words (e.g. "Service  Charge" / "Service-Charge"
                // / "Frais\tde service"). Replacing the literal space
                // in the compiled pattern with `[\s\-]+` keeps every
                // single-spaced match working while picking up the
                // mangled variants. Bare single-word entries (`fee`,
                // `surcharge`, …) are unaffected because they contain
                // no space to substitute.
                return escaped.replacingOccurrences(of: " ", with: #"[\s\-]+"#)
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
