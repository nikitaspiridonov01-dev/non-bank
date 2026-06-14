import { describe, expect, it } from "vitest";
import {
  isValidPairHmac,
  isValidUserId,
  isValidSyncId,
  isValidVersion,
  isValidOp,
  nextUtcDayStart,
} from "../src/sync.ts";

describe("isValidPairHmac", () => {
  it("accepts 64-char lowercase hex", () => {
    expect(isValidPairHmac("a".repeat(64))).toBe(true);
    expect(isValidPairHmac("0123456789abcdef".repeat(4))).toBe(true);
  });
  it("rejects wrong length, uppercase, non-hex, non-string", () => {
    expect(isValidPairHmac("a".repeat(63))).toBe(false);
    expect(isValidPairHmac("A".repeat(64))).toBe(false);
    expect(isValidPairHmac("g".repeat(64))).toBe(false);
    expect(isValidPairHmac(123)).toBe(false);
    expect(isValidPairHmac(null)).toBe(false);
  });
});

describe("isValidUserId", () => {
  it("accepts 3..64 char strings", () => {
    expect(isValidUserId("abc")).toBe(true);
    expect(isValidUserId("brave-otter-2931")).toBe(true);
    expect(isValidUserId("x".repeat(64))).toBe(true);
  });
  it("rejects too short / too long / non-string", () => {
    expect(isValidUserId("ab")).toBe(false);
    expect(isValidUserId("x".repeat(65))).toBe(false);
    expect(isValidUserId("")).toBe(false);
    expect(isValidUserId(42)).toBe(false);
  });
});

describe("isValidSyncId", () => {
  it("accepts 1..128 char strings", () => {
    expect(isValidSyncId("t")).toBe(true);
    expect(isValidSyncId("tx-abc-123")).toBe(true);
    expect(isValidSyncId("z".repeat(128))).toBe(true);
  });
  it("rejects empty / oversized / non-string", () => {
    expect(isValidSyncId("")).toBe(false);
    expect(isValidSyncId("z".repeat(129))).toBe(false);
    expect(isValidSyncId(undefined)).toBe(false);
  });
});

describe("isValidVersion", () => {
  it("accepts non-negative integers", () => {
    expect(isValidVersion(0)).toBe(true);
    expect(isValidVersion(1)).toBe(true);
    expect(isValidVersion(9999)).toBe(true);
  });
  it("rejects negatives, floats, non-numbers", () => {
    expect(isValidVersion(-1)).toBe(false);
    expect(isValidVersion(1.5)).toBe(false);
    expect(isValidVersion("3")).toBe(false);
    expect(isValidVersion(NaN)).toBe(false);
  });
});

describe("isValidOp", () => {
  it("accepts only 'upsert' and 'delete'", () => {
    expect(isValidOp("upsert")).toBe(true);
    expect(isValidOp("delete")).toBe(true);
    expect(isValidOp("update")).toBe(false);
    expect(isValidOp("")).toBe(false);
    expect(isValidOp(null)).toBe(false);
  });
});

describe("nextUtcDayStart", () => {
  it("returns the start of the next UTC day", () => {
    // 2026-01-01T12:00:00Z -> 2026-01-02T00:00:00Z
    const noon = Date.UTC(2026, 0, 1, 12, 0, 0) / 1000;
    const next = Date.UTC(2026, 0, 2, 0, 0, 0) / 1000;
    expect(nextUtcDayStart(noon)).toBe(next);
  });
  it("rolls to the next day even at one second before midnight", () => {
    const justBefore = Date.UTC(2026, 0, 1, 23, 59, 59) / 1000;
    const next = Date.UTC(2026, 0, 2, 0, 0, 0) / 1000;
    expect(nextUtcDayStart(justBefore)).toBe(next);
  });
  it("is always strictly in the future", () => {
    const now = Date.UTC(2026, 5, 14, 8, 30, 0) / 1000;
    expect(nextUtcDayStart(now)).toBeGreaterThan(now);
  });
});
