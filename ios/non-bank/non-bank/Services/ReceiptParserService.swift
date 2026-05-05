import UIKit
import FoundationModels

// MARK: - Generable Types for Foundation Models

@Generable(description: "A single purchased item from a receipt")
struct GenerableReceiptItem {
    @Guide(description: "Product or service name as written on the receipt")
    var name: String

    @Guide(description: "Quantity purchased, usually 1", .range(1...999))
    var quantity: Int

    @Guide(description: "Price per unit as a plain decimal number, e.g. 1100.00 not 1,100.00")
    var price: Double

    @Guide(description: "Line total (quantity × price) as a plain decimal number")
    var total: Double
}

@Generable(description: "Structured data extracted from a receipt")
struct GenerableReceipt {
    @Guide(description: "Store or restaurant name")
    var storeName: String

    @Guide(description: "Date in YYYY-MM-DD format")
    var date: String

    @Guide(description: "ISO 4217 currency code, e.g. RSD, EUR, USD")
    var currency: String

    @Guide(description: "All purchased items listed on the receipt")
    var items: [GenerableReceiptItem]

    @Guide(description: "Grand total amount as a plain decimal number")
    var totalAmount: Double
}

// MARK: - Receipt Parser Service (OCR + Foundation Models)

/// Extracts structured receipt data using Apple Vision OCR + Apple Foundation Models.
/// Pipeline: Image → Vision OCR → text → on-device LLM (guided generation) → ParsedReceipt.
/// Free, local, offline. Zero model downloads — uses the system Apple Intelligence model.
actor ReceiptParserService {
    private let ocr = ReceiptOCRService()

    // Debug properties
    private(set) var lastOCRText: String = ""
    private(set) var lastWordCount: Int = 0

    // MARK: - Public API

    func parseReceipt(from image: UIImage) async throws -> ParsedReceipt {
        lastOCRText = ""
        lastWordCount = 0

        // 1. Check Foundation Models availability *before* OCR — saves a full
        // OCR pass on devices without Apple Intelligence so the hybrid parser
        // can fall through to its regex strategy quickly.
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw ReceiptParserError.modelUnavailable
        }

        // 2. Run OCR — get text from image
        let lines = try await ocr.recognizeText(from: image)
        let ocrText = await ocr.buildReceiptText(from: lines)
        lastOCRText = ocrText
        lastWordCount = ocrText.split(separator: " ").count
        print("[ReceiptParser] OCR returned \(lines.count) lines, \(lastWordCount) words")

        guard !ocrText.isEmpty else {
            return ParsedReceipt(storeName: nil, date: nil, items: [], totalAmount: nil, currency: nil)
        }

        // 3. Create session with receipt-parsing instructions
        let session = LanguageModelSession(instructions: Self.instructions)

        // 4. Generate structured receipt using guided generation
        let prompt = "Extract all purchased items from this receipt:\n\n\(ocrText)"
        print("[ReceiptParser] Sending \(prompt.count) chars to Foundation Models...")

        let response = try await session.respond(to: prompt, generating: GenerableReceipt.self)
        let generated = response.content
        print("[ReceiptParser] Got \(generated.items.count) items, total=\(generated.totalAmount)")

        // 5. Convert to ParsedReceipt
        let items = generated.items.map { item in
            ReceiptItem(
                name: item.name,
                quantity: Double(item.quantity),
                price: item.price,
                total: item.total
            )
        }.filter { $0.isUsable }

        return ParsedReceipt(
            storeName: generated.storeName.isEmpty ? nil : generated.storeName,
            date: generated.date.isEmpty ? nil : generated.date,
            items: items,
            totalAmount: generated.totalAmount,
            currency: generated.currency.isEmpty ? nil : generated.currency
        )
    }

    // MARK: - Instructions

    private static let instructions = Instructions("""
    You are a receipt parser. Given OCR text from a receipt photo OR a digital
    order summary (Wolt, Uber Eats, Glovo, Bolt Food), extract all purchased
    items.

    Items to EXTRACT (positive line totals):
    - Every food / drink / product line
    - Delivery fee — yes, count it as an item with name "Delivery"
    - Packaging / bag fee — count as an item

    Items to EXTRACT as NEGATIVE line totals (deductions):
    - Discount, promo, voucher, coupon, loyalty discount, rebate
    - Russian "скидка" / German "Rabatt" / French "remise" / Italian "sconto"
      / Spanish "descuento" / Polish "rabat" / Serbian "popust"
    - The line total should be NEGATIVE: e.g. price = -2.50, total = -2.50
    - If the discount is shown as "-2,50" or "−2,50", emit total = -2.50
    - If the discount has a percentage but no absolute amount, skip it

    Items to SKIP:
    - Tax / VAT / NDS / TVA / IVA / MwSt lines
    - Subtotal / sub-total / Zwischensumme / Międzysuma
    - Grand total / TOTAL / Итого / Gesamt — NEVER include as an item
    - Tip / gratuity / service charge — these are payments, not items
    - Cash / card / Visa / Mastercard / "Card *1234" payment rows
    - Change / refund / Сдача / Rückgeld / Reszta
    - Phone / address / tax ID / receipt number / waiter / table / cashier
    - Date / time on its own line
    - Strikethrough / crossed-out price next to a final price — keep ONLY
      the final price (the smaller, non-strikethrough one)

    Number formatting:
    - Prices must be plain decimal numbers: 1100.00 not 1,100.00 or 1.100,00
    - 1.100,00 → 1100.00 (EU thousands, comma decimal)
    - 550,00 → 550.00 (EU comma decimal)
    - 5,5 → 5.50 (1-decimal accepted)
    - 250 → 250.00 (integer prices accepted, common on RSD/JPY/HUF receipts)
    - quantity is usually 1 unless explicitly stated like "2x" or "3 ×"
    - total = quantity × price for each item (or negative for discounts)

    Receipt without a TOTAL line:
    - This is fine. Set totalAmount = 0 and emit all items.
    - This happens often on order summaries that show a list of items but
      were screenshotted before the totals card.

    Multi-guest receipts (Guest 1, Guest 2, Table 5 - Guest 1, etc.):
    - Extract items from EVERY guest section. Do not stop at the first
      sub-total. The grand total is the last one if there are several.

    Metadata:
    - storeName: the restaurant or store name, usually at the top
    - date: convert to YYYY-MM-DD format
    - currency: use ISO 4217 code (RSD for Serbian dinar, EUR, USD, RUB,
      PLN, CZK, etc.). If the receipt is from Serbia (Belgrade, has RSD
      prices), currency is RSD.
    """)
}

// MARK: - Errors

enum ReceiptParserError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Intelligence is not available on this device. Please enable it in Settings."
        }
    }
}
