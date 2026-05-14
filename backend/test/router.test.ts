import { describe, expect, it } from "vitest";
import { coerceReceipt, extractJSON } from "../src/providers/base.ts";

describe("extractJSON", () => {
  it("parses bare JSON", () => {
    const out = extractJSON('{"foo":1}', "groq");
    expect(out).toEqual({ foo: 1 });
  });

  it("strips ```json fences", () => {
    const out = extractJSON("```json\n{\"foo\":2}\n```", "groq");
    expect(out).toEqual({ foo: 2 });
  });

  it("recovers JSON wrapped in prose", () => {
    const out = extractJSON(
      "Here you go: {\"items\":[{\"name\":\"Coffee\",\"total\":3.5}]} hope this helps!",
      "openrouter",
    );
    expect(out).toEqual({ items: [{ name: "Coffee", total: 3.5 }] });
  });

  it("throws bad_response on garbage", () => {
    expect(() => extractJSON("totally not json", "groq")).toThrow(
      /could not extract JSON/,
    );
  });
});

describe("coerceReceipt", () => {
  it("normalizes a well-formed payload", () => {
    const out = coerceReceipt(
      {
        storeName: "  Maxi  ",
        date: "2026-05-01",
        currency: "RSD",
        totalAmount: 1450,
        suggestedCategory: "Groceries",
        items: [
          { name: "Milk 1L", quantity: 1, price: 219, total: 219 },
          { name: "Bread", quantity: 2, price: 75, total: 150 },
        ],
      },
      "gemini",
    );
    expect(out.storeName).toBe("Maxi");
    expect(out.totalAmount).toBe(1450);
    expect(out.suggestedCategory).toBe("Groceries");
    expect(out.items).toHaveLength(2);
  });

  it("recovers EU-decimal numeric strings", () => {
    const out = coerceReceipt(
      {
        currency: "EUR",
        totalAmount: "1.100,00",
        items: [{ name: "X", total: "550,00" }],
      },
      "openrouter",
    );
    expect(out.totalAmount).toBe(1100);
    expect(out.items[0].total).toBe(550);
  });

  it("filters out unusable items (no price/total)", () => {
    const out = coerceReceipt(
      {
        items: [
          { name: "Real item", total: 5 },
          { name: "Garbage", total: 0, price: 0 },
          { name: "", total: 99 },
        ],
      },
      "gemini",
    );
    expect(out.items).toHaveLength(1);
    expect(out.items[0].name).toBe("Real item");
  });

  it("keeps negative discount items", () => {
    const out = coerceReceipt(
      {
        items: [
          { name: "Coffee", total: 3.5 },
          { name: "Loyalty discount", total: -0.5 },
        ],
      },
      "groq",
    );
    expect(out.items).toHaveLength(2);
    expect(out.items[1].total).toBe(-0.5);
  });

  it("flips a single-item receipt's negative total to positive", () => {
    // Real-world case: LLM emitted OPENAI *CHATGPT SUBSCR as -20 USD.
    // A single-line receipt can't be a discount — it's the full charge.
    const out = coerceReceipt(
      {
        items: [{ name: "OPENAI *CHATGPT SUBSCR", total: -20, price: -20 }],
      },
      "gemini",
    );
    expect(out.items).toHaveLength(1);
    expect(out.items[0].total).toBe(20);
    expect(out.items[0].price).toBe(20);
  });

  it("flips all-negative receipts to all-positive", () => {
    // LLM occasionally inverts the whole receipt sign — defensive flip.
    const out = coerceReceipt(
      {
        items: [
          { name: "Pasta", total: -1290 },
          { name: "Salad", total: -1490 },
        ],
      },
      "groq",
    );
    expect(out.items.every((i) => (i.total ?? 0) > 0)).toBe(true);
  });

  it("preserves a discount line when other items are positive", () => {
    // Don't over-correct: a real discount in a multi-item receipt stays
    // negative even if its name doesn't trip the keyword list.
    const out = coerceReceipt(
      {
        items: [
          { name: "Latte", total: 4 },
          { name: "Espresso", total: 3 },
          { name: "Member benefit", total: -1 },
        ],
      },
      "openrouter",
    );
    const member = out.items.find((i) => i.name === "Member benefit")!;
    expect(member.total).toBe(-1);
  });

  it("throws bad_response on non-object root", () => {
    expect(() => coerceReceipt("hello", "groq")).toThrow();
    expect(() => coerceReceipt([], "groq")).toThrow();
  });

  it("treats missing optional fields as null", () => {
    const out = coerceReceipt({ items: [{ name: "X", total: 1 }] }, "gemini");
    expect(out.storeName).toBeNull();
    expect(out.suggestedCategory).toBeNull();
    expect(out.currency).toBeNull();
  });
});
