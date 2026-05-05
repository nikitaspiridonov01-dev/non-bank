import NaturalLanguage

/// NLP utilities for receipt text analysis.
/// Provides language detection, currency detection, and multi-language keyword dictionaries.
struct ReceiptNLPService: Sendable {

    // MARK: - Language Detection

    /// Detect the dominant language of the receipt text.
    /// Returns ISO 639-1 code (e.g. "sr", "ru", "en", "de") or "und" if unknown.
    static func detectLanguage(text: String) -> String {
        let lower = text.lowercased()

        // Keyword override: NLLanguageRecognizer confuses Serbian Cyrillic with Russian.
        // These words are uniquely Serbian and never appear in Russian.
        let serbianOnly = ["рачун", "укупно", "артикли", "готовина", "порез", "београд", "пдв", "ознака"]
        let serbianHits = serbianOnly.filter { lower.contains($0) }.count
        if serbianHits >= 2 { return "sr" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return "und" }

        switch lang {
        case .russian: return "ru"
        case .english: return "en"
        case .german: return "de"
        case .french: return "fr"
        case .spanish: return "es"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .simplifiedChinese, .traditionalChinese: return "zh"
        case .turkish: return "tr"
        case .dutch: return "nl"
        case .polish: return "pl"
        case .czech: return "cs"
        case .croatian: return "hr"
        default:
            let raw = lang.rawValue
            if raw == "sr" || raw.hasPrefix("sr-") { return "sr" }
            if raw == "bs" || raw.hasPrefix("bs-") { return "sr" }
            return raw
        }
    }

    // MARK: - Currency Detection

    /// Detect currency from receipt text using language and currency symbols/keywords.
    static func detectCurrency(text: String, language: String) -> String {
        let lower = text.lowercased()

        // Check for explicit currency symbols first (language-independent)
        if lower.contains("€") || lower.contains("eur") { return "EUR" }
        if lower.contains("$") && !lower.contains("₽") { return "USD" }
        if lower.contains("£") || lower.contains("gbp") { return "GBP" }
        if lower.contains("₽") || lower.contains("руб") { return "RUB" }
        if lower.contains("¥") || lower.contains("円") { return "JPY" }
        if lower.contains("₩") || lower.contains("원") { return "KRW" }
        if lower.contains("дин") { return "RSD" }
        if lower.contains("kč") || lower.contains("czk") { return "CZK" }
        if lower.contains("zł") || lower.contains("pln") { return "PLN" }
        if lower.contains("kn") || lower.contains("hrk") { return "HRK" }
        if lower.contains("chf") { return "CHF" }

        // Infer from language
        switch language {
        case "sr": return "RSD"
        case "ru": return "RUB"
        case "ja": return "JPY"
        case "ko": return "KRW"
        case "zh": return "CNY"
        case "tr": return "TRY"
        case "pl": return "PLN"
        case "cs": return "CZK"
        case "en":
            if lower.contains("£") || lower.contains("vat") { return "GBP" }
            return "USD"
        case "de", "fr", "es", "it", "pt", "nl":
            return "EUR"
        default:
            return "USD"
        }
    }

    // MARK: - Multi-Language Keyword Dictionaries

    /// Keywords that indicate a "total" line on a receipt (multi-language).
    static func totalKeywords(for language: String) -> [String] {
        var keywords: [String] = []
        keywords.append(contentsOf: ["total", "sum", "summe"])

        switch language {
        case "sr", "hr":
            keywords.append(contentsOf: ["укупно", "свега", "zbir", "ukupno"])
        case "ru":
            keywords.append(contentsOf: ["итого", "всего", "сумма"])
        case "de":
            keywords.append(contentsOf: ["gesamt", "summe", "betrag", "total"])
        case "fr":
            keywords.append(contentsOf: ["total", "montant", "somme"])
        case "es":
            keywords.append(contentsOf: ["total", "importe", "suma"])
        case "it":
            keywords.append(contentsOf: ["totale", "importo", "somma"])
        case "pt":
            keywords.append(contentsOf: ["total", "valor", "soma"])
        case "ja":
            keywords.append(contentsOf: ["合計", "小計", "税込"])
        case "ko":
            keywords.append(contentsOf: ["합계", "총액", "소계"])
        case "zh":
            keywords.append(contentsOf: ["合计", "总计", "小计", "总额"])
        case "tr":
            keywords.append(contentsOf: ["toplam", "tutar", "genel"])
        case "pl":
            keywords.append(contentsOf: ["razem", "suma", "łącznie", "ogółem"])
        case "cs":
            keywords.append(contentsOf: ["celkem", "součet", "úhrn"])
        case "nl":
            keywords.append(contentsOf: ["totaal", "bedrag", "som"])
        default:
            break
        }

        return keywords
    }

    /// Receipt structure keywords to filter (subtotal labels, tax labels, payment labels, etc.)
    static func receiptStructureKeywords(for language: String) -> [String] {
        var keywords: [String] = []

        keywords.append(contentsOf: [
            "subtotal", "tax", "vat", "change", "cash", "card", "visa", "mastercard",
            "receipt", "invoice", "fiscal", "payment",
        ])

        switch language {
        case "sr", "hr":
            keywords.append(contentsOf: [
                "укупно", "порез", "назив", "цена", "кол.", "стопа", "ознака",
                "пдв", "готовина", "артикли", "промет", "продала", "продажа",
                "фискални", "рачун", "износ", "време", "повраћај",
                "картица", "картичн", "бро", "укупан",
            ])
        case "ru":
            keywords.append(contentsOf: [
                "итого", "ндс", "налог", "кассовый", "чек", "касс",
                "наличн", "безналичн", "сдача", "адрес", "тел",
                "фискальн", "смена", "кассир", "покупатель",
            ])
        case "de":
            keywords.append(contentsOf: [
                "gesamt", "mwst", "steuer", "netto", "brutto", "bar",
                "karte", "beleg", "bon", "rechnung", "kassenbon",
                "zwischensumme", "steuernummer", "ust",
            ])
        case "fr":
            keywords.append(contentsOf: [
                "total", "tva", "taxe", "net", "brut", "espèces",
                "carte", "reçu", "facture", "ticket", "caisse",
                "sous-total", "montant", "rendu",
            ])
        case "es":
            keywords.append(contentsOf: [
                "total", "iva", "impuesto", "neto", "bruto", "efectivo",
                "tarjeta", "recibo", "factura", "ticket", "caja",
                "subtotal", "cambio",
            ])
        case "it":
            keywords.append(contentsOf: [
                "totale", "iva", "imposta", "netto", "lordo", "contanti",
                "carta", "ricevuta", "scontrino", "cassa",
                "subtotale", "resto",
            ])
        case "ja":
            keywords.append(contentsOf: [
                "合計", "小計", "税", "消費税", "内税", "外税",
                "現金", "クレジット", "お釣り", "領収書", "レシート",
            ])
        case "ko":
            keywords.append(contentsOf: [
                "합계", "소계", "부가세", "세금", "현금", "카드",
                "거스름", "영수증",
            ])
        case "zh":
            keywords.append(contentsOf: [
                "合计", "小计", "税", "增值税", "现金", "找零",
                "收据", "发票",
            ])
        case "tr":
            keywords.append(contentsOf: [
                "toplam", "kdv", "vergi", "nakit", "kart",
                "fiş", "fatura", "ara toplam", "üstü",
            ])
        case "pl":
            keywords.append(contentsOf: [
                "razem", "podatek", "vat", "gotówka", "karta",
                "paragon", "rachunek", "suma", "reszta",
            ])
        default:
            break
        }

        return keywords
    }
}
