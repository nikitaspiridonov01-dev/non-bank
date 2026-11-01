import { describe, expect, it } from "vitest";
import {
  CUT_PLACEHOLDER,
  RECEIPT_SYSTEM_PROMPT,
  RECEIPT_SYSTEM_PROMPT_TWO_LINE_ROWS,
  SLICE_NOTE,
  buildUserPrompt,
  dropCutPlaceholders,
  receiptSystemPrompt,
} from "../src/prompt.ts";

describe("two-line-row prompt revision", () => {
  const v2 = RECEIPT_SYSTEM_PROMPT_TWO_LINE_ROWS;

  it("adds the two-line-row section before the multi-line names section", () => {
    const rule = v2.indexOf("# Two-line rows — a NUMBERS-ONLY line belongs to the name ABOVE it");
    const multiline = v2.indexOf("# Multi-line item names & indented add-ons");
    expect(rule).toBeGreaterThan(0);
    expect(multiline).toBeGreaterThan(rule);
    expect(v2).toContain("Назив Цена Кол. Укупно");
  });

  it("narrows the restaurant same-row rule instead of contradicting the new one", () => {
    expect(RECEIPT_SYSTEM_PROMPT).toContain("- A `name` and its `total` MUST come from the SAME printed row.");
    expect(v2).not.toContain("- A `name` and its `total` MUST come from the SAME printed row.");
    expect(v2).toContain("where an amount is printed on the same row as its name");
  });

  it("adds a fourth pre-emit check", () => {
    expect(v2).toContain("re-scan your items list for four specific failure modes:");
    expect(v2).toContain("4. **Two-line rows.**");
    // The check list still ends where it did.
    expect(v2.indexOf("4. **Two-line rows.**")).toBeLessThan(v2.indexOf("Only after all passes, emit the JSON."));
  });

  it("leaves the rest of the prompt untouched", () => {
    const head = RECEIPT_SYSTEM_PROMPT.indexOf("# Multi-line item names");
    expect(v2.startsWith(RECEIPT_SYSTEM_PROMPT.slice(0, head - 1).replace(/\n+$/, ""))).toBe(true);
    const tail = RECEIPT_SYSTEM_PROMPT.slice(RECEIPT_SYSTEM_PROMPT.indexOf("Only after all passes"));
    expect(v2.endsWith(tail)).toBe(true);
    // Everything except the three edits and the new section is identical.
    expect(v2.length - RECEIPT_SYSTEM_PROMPT.length).toBeGreaterThan(1500);
    expect(v2.length - RECEIPT_SYSTEM_PROMPT.length).toBeLessThan(3500);
  });

  it("is chosen per request", () => {
    expect(receiptSystemPrompt({})).toBe(RECEIPT_SYSTEM_PROMPT);
    expect(receiptSystemPrompt({ twoLineRows: false })).toBe(RECEIPT_SYSTEM_PROMPT);
    expect(receiptSystemPrompt({ twoLineRows: true })).toBe(v2);
  });
});

describe("slice note in the user prompt", () => {
  const cats = [{ name: "Groceries", emoji: "🛒" }];

  it("is absent for whole receipts", () => {
    const p = buildUserPrompt(cats, "sr_RS");
    expect(p).not.toContain("ONE SLICE");
    expect(p).toContain("- 🛒 Groceries");
    expect(p).toContain("User locale hint: sr_RS");
  });

  it("is added for slices, before the category list", () => {
    const p = buildUserPrompt(cats, "sr_RS", true);
    expect(p).toContain(SLICE_NOTE);
    expect(p.indexOf(SLICE_NOTE)).toBeLessThan(p.indexOf("User's existing categories"));
    expect(p).toContain("- 🛒 Groceries");
  });
});

describe("orphan top line of a slice", () => {
  it("is parked under the placeholder name instead of the next product's", () => {
    expect(SLICE_NOTE).toContain(`named exactly "${CUT_PLACEHOLDER}"`);
    expect(SLICE_NOTE).toContain("Never give the orphan line to the name below it.");
  });

  it("is dropped from the slice's items, whatever the model's casing or spacing", () => {
    const items = [
      { name: "(cut)", total: 169.99 },
      { name: " (CUT) ", total: 506.99 },
      { name: "MUSLI PROTEIN 250GR", total: 374.99 },
      { name: "Cut flowers (cut)", total: 299 },
    ];
    expect(dropCutPlaceholders(items).map((i) => i.total)).toEqual([374.99, 299]);
  });
});
