import { describe, expect, it } from "vitest";
import { route, RouterExhaustedError } from "../src/router.ts";
import type { Provider } from "../src/providers/base.ts";
import type { ParsedReceipt, ProviderId } from "../src/types.ts";
import type { ProviderQuotaRow } from "../src/quota.ts";

// In-memory stand-in for the four `provider_quotas` statements the router
// runs: the daily self-reset, the snapshot read, recordSuccess, recordError.
class FakeQuotaDB {
  rows: ProviderQuotaRow[];
  constructor(providers: ProviderId[]) {
    this.rows = providers.map((provider) => ({
      provider,
      rpd_used: 0,
      rpd_limit: 1000,
      reset_at: 4_000_000_000,
      consecutive_errors: 0,
      last_error_at: null,
      last_success_at: null,
      total_requests: 0,
      total_errors: 0,
    }));
  }
  prepare(sql: string) {
    let args: unknown[] = [];
    const statement = {
      bind: (...a: unknown[]) => {
        args = a;
        return statement;
      },
      all: async () => ({ results: this.rows.map((r) => ({ ...r })) }),
      run: async () => {
        const row = this.rows.find((r) => r.provider === args[0]);
        if (row && sql.includes("consecutive_errors = consecutive_errors + 1")) {
          row.consecutive_errors += 1;
          row.total_errors += 1;
          row.rpd_used += Number(args[2] ?? 0);
        } else if (row && sql.includes("rpd_used = rpd_used + 1")) {
          row.rpd_used += 1;
          row.consecutive_errors = 0;
        }
        return { success: true };
      },
    };
    return statement;
  }
  errors(provider: ProviderId): number {
    return this.rows.find((r) => r.provider === provider)!.consecutive_errors;
  }
}

function receipt(items: number, totalAmount: number | null = null): ParsedReceipt {
  return {
    storeName: null,
    date: null,
    currency: "RSD",
    totalAmount,
    suggestedCategory: null,
    language: null,
    items: Array.from({ length: items }, (_, i) => ({ name: `Item ${i + 1}`, quantity: 1, price: 100, total: 100 })),
  };
}

// Providers answer in QUALITY_RANK order when quota headroom is equal:
// gemini, mistral, groq, nvidia.
function stubs(answers: Partial<Record<ProviderId, ParsedReceipt | Error>>) {
  const calls: ProviderId[] = [];
  const providers: Partial<Record<ProviderId, Provider>> = {};
  for (const [id, answer] of Object.entries(answers) as Array<[ProviderId, ParsedReceipt | Error]>) {
    providers[id] = {
      id,
      dailyLimit: 1000,
      parse: async () => {
        calls.push(id);
        if (answer instanceof Error) throw answer;
        return { receipt: answer };
      },
    };
  }
  return { providers, calls };
}

const req = { imageBytes: new Uint8Array([1]), imageMime: "image/jpeg", categories: [] };
const NOW = 1_800_000_000;

function env(db: FakeQuotaDB) {
  return { DB: db as unknown as D1Database };
}

describe("route — band mode (one slice of a tall receipt)", () => {
  it("accepts an empty band once two models agree, without error streaks", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral", "groq", "nvidia"]);
    const { providers, calls } = stubs({
      gemini: receipt(0, 4564.4),
      mistral: receipt(0),
      groq: receipt(3),
      nvidia: receipt(3),
    });
    const out = await route(req, env(db), NOW, undefined, { band: true, providers });
    expect(calls).toEqual(["gemini", "mistral"]);
    expect(out.receipt.items).toHaveLength(0);
    // The footer band's grand total survives, from the first model that read it.
    expect(out.receipt.totalAmount).toBe(4564.4);
    expect(out.provider).toBe("mistral");
    expect(out.triedProviders.map((t) => t.provider)).toEqual(["gemini"]);
    expect(db.errors("gemini")).toBe(0);
    expect(db.errors("mistral")).toBe(0);
  });

  it("takes a second model's items over the first model's empty answer", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral", "groq"]);
    const { providers, calls } = stubs({ gemini: receipt(0), mistral: receipt(4), groq: receipt(2) });
    const out = await route(req, env(db), NOW, undefined, { band: true, providers });
    expect(calls).toEqual(["gemini", "mistral"]);
    expect(out.receipt.items).toHaveLength(4);
    expect(out.provider).toBe("mistral");
  });

  it("counts a provider error between the two empty answers as a failed attempt", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral", "groq"]);
    const { providers, calls } = stubs({
      gemini: receipt(0),
      mistral: new Error("upstream 500"),
      groq: receipt(0),
    });
    const out = await route(req, env(db), NOW, undefined, { band: true, providers });
    expect(calls).toEqual(["gemini", "mistral", "groq"]);
    expect(out.receipt.items).toHaveLength(0);
    expect(out.provider).toBe("groq");
    expect(out.triedProviders.map((t) => t.provider)).toEqual(["gemini", "mistral"]);
    expect(db.errors("mistral")).toBe(1);
  });

  it("returns a lone empty answer when no second model is left, instead of a 503", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral"]);
    const { providers } = stubs({ gemini: receipt(0, 120), mistral: new Error("rate limited") });
    const out = await route(req, env(db), NOW, undefined, { band: true, providers });
    expect(out.receipt.items).toHaveLength(0);
    expect(out.receipt.totalAmount).toBe(120);
    expect(out.provider).toBe("gemini");
    expect(out.triedProviders.map((t) => t.provider)).toEqual(["mistral"]);
  });

  it("still fails when every provider errors", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral"]);
    const { providers } = stubs({ gemini: new Error("a"), mistral: new Error("b") });
    await expect(route(req, env(db), NOW, undefined, { band: true, providers })).rejects.toBeInstanceOf(
      RouterExhaustedError,
    );
  });
});

describe("route — whole receipts (no band flag) are unchanged", () => {
  it("treats an empty answer as a misread and walks the whole pool", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral", "groq"]);
    const { providers, calls } = stubs({ gemini: receipt(0), mistral: receipt(0), groq: receipt(0) });
    await expect(route(req, env(db), NOW, undefined, { providers })).rejects.toBeInstanceOf(RouterExhaustedError);
    expect(calls).toEqual(["gemini", "mistral", "groq"]);
    expect(db.errors("gemini")).toBe(1);
  });

  it("moves past an empty answer to the next model's items", async () => {
    const db = new FakeQuotaDB(["gemini", "mistral"]);
    const { providers } = stubs({ gemini: receipt(0), mistral: receipt(2) });
    const out = await route(req, env(db), NOW, undefined, { providers });
    expect(out.receipt.items).toHaveLength(2);
    expect(out.provider).toBe("mistral");
  });
});
