// Structured JSON logger. Each log line is a single JSON object which
// Cloudflare's `wrangler tail` and Logpush ingest natively — no parsing
// hacks downstream. Replaces ad-hoc `console.error("unhandled", e)` calls
// scattered through the entry-point so a post-incident search has the
// fields you'd actually want to filter on (ip_hash, device_hash, route,
// provider, latency_ms, status, error_kind).
//
// LOG_LEVEL semantics:
//   "silent" — emit nothing (tests, throwaway dev)
//   "error"  — only events with level ∈ {error, warn}
//   "info"   — everything (default, production)
//
// IP_HASH and device hash should already be one-way digests by the time
// they reach this logger — no PII in raw logs.

export type LogLevel = "info" | "warn" | "error";

interface LogContext {
  LOG_LEVEL?: string;
}

export function logEvent(
  env: LogContext,
  level: LogLevel,
  fields: Record<string, unknown>,
): void {
  const configured = (env.LOG_LEVEL ?? "info").toLowerCase();
  if (configured === "silent") return;
  if (configured === "error" && level === "info") return;

  // `console.log` for info, `console.error` for warn/error — keeps the
  // Cloudflare dashboard severity colouring sensible without forcing the
  // caller to think about which method to use.
  const line = JSON.stringify({
    ts: Date.now(),
    level,
    ...fields,
  });
  if (level === "info") {
    console.log(line);
  } else {
    console.error(line);
  }
}
