// APNs token-based (JWT/ES256) push sender for the Worker — Phase 3.
//
// Sends a lightweight "new shared expense" alert when a delivery is
// uploaded, so the recipient gets an immediate nudge instead of waiting for
// their next foreground pull. The push carries NO financial content — the
// actual encrypted delivery is still pulled from /v1/sync/inbox on receipt/
// open. Best-effort throughout: if APNs isn't configured or a send fails,
// sync still works via pull.

import { getDeviceTokens } from "./sync.ts";
import type { Env } from "./index.ts";

export interface ApnsConfig {
  keyP8: string;    // PEM contents of the APNs auth key (.p8)
  keyId: string;    // APNs Key ID (10 chars)
  teamId: string;   // Apple Developer Team ID
  bundleId: string; // app bundle id — the apns-topic
}

interface ApnsEnv {
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APP_ATTEST_APP_ID?: string; // "<TEAMID>.<bundle>" — reused for team + bundle
}

/// Build config from env, or null when push isn't configured (the
/// APNS_KEY_P8 / APNS_KEY_ID secrets aren't set). Null disables push
/// cleanly — the rest of sync is unaffected.
export function apnsConfigFromEnv(env: ApnsEnv): ApnsConfig | null {
  const keyP8 = env.APNS_KEY_P8?.trim();
  const keyId = env.APNS_KEY_ID?.trim();
  const appId = env.APP_ATTEST_APP_ID?.trim();
  if (!keyP8 || !keyId || !appId) return null;
  const dot = appId.indexOf(".");
  if (dot < 0) return null;
  return { keyP8, keyId, teamId: appId.slice(0, dot), bundleId: appId.slice(dot + 1) };
}

// Provider JWT cache (per isolate). APNs allows reuse up to ~60 min; refresh
// at 50 to stay safely inside the window and avoid re-signing per push.
let cachedJwt: { token: string; exp: number } | null = null;

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u8) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlString(s: string): string {
  return base64url(new TextEncoder().encode(s));
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function providerJWT(config: ApnsConfig, nowSec: number): Promise<string> {
  if (cachedJwt && cachedJwt.exp > nowSec) return cachedJwt.token;
  const header = base64urlString(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64urlString(JSON.stringify({ iss: config.teamId, iat: nowSec }));
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(config.keyP8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  // WebCrypto ECDSA returns the raw r||s signature — exactly JOSE ES256.
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${base64url(sig)}`;
  cachedJwt = { token: jwt, exp: nowSec + 50 * 60 };
  return jwt;
}

/// Send one alert push to a device token. Returns true on APNs 200.
/// Best-effort: any error → false (recipient still gets the delivery via
/// pull). `apnsEnv` selects the host: 'sandbox' for Xcode dev builds,
/// 'production' for TestFlight / App Store.
export async function sendPush(
  config: ApnsConfig,
  deviceToken: string,
  apnsEnv: string,
  alert: { title: string; body: string },
  nowSec: number,
  data?: Record<string, unknown>,
): Promise<boolean> {
  try {
    const jwt = await providerJWT(config, nowSec);
    const host = apnsEnv === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
    // Custom top-level keys (alongside `aps`) carry the opaque tx_sync_id so
    // a notification TAP can deep-link straight to that transaction once the
    // pull applies it. No financial content — just the routing token.
    const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": config.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: JSON.stringify({ aps: { alert, sound: "default" }, ...(data ?? {}) }),
    });
    return res.status === 200;
  } catch {
    return false;
  }
}

/// Send one SILENT (content-available) background push — no alert/sound, it
/// just wakes the app to fetch. Background pushes MUST use apns-push-type
/// "background" + apns-priority 5 (Apple rejects priority 10 for these).
/// Best-effort: any error → false.
export async function sendBackgroundPush(
  config: ApnsConfig,
  deviceToken: string,
  apnsEnv: string,
  nowSec: number,
  data?: Record<string, unknown>,
): Promise<boolean> {
  try {
    const jwt = await providerJWT(config, nowSec);
    const host = apnsEnv === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
    const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": config.bundleId,
        "apns-push-type": "background",
        "apns-priority": "5",
      },
      body: JSON.stringify({ aps: { "content-available": 1 }, ...(data ?? {}) }),
    });
    return res.status === 200;
  } catch {
    return false;
  }
}

/// Wake the SHARER's app when a friend completes the reciprocal pairing
/// handshake (an `op="pair"` delivery addressed to them) via a SILENT
/// background push. There is deliberately NO visible alert here: the app pulls
/// the handshake and posts its OWN local "you're now synced with <name>"
/// notification (the server is zero-knowledge and can't put the friend's name
/// in a push). Costs one device-token read per pairing event (rare) and no
/// writes. Best-effort + iOS-throttled like any background push — if dropped,
/// the handshake still applies on the next foreground pull.
export async function sendPairingPush(
  env: Env,
  recipientId: string,
  nowSec: number,
): Promise<void> {
  const config = apnsConfigFromEnv(env);
  if (!config) return; // push not configured — pull still applies the handshake
  const tokens = await getDeviceTokens(env.DB, recipientId);
  if (tokens.length === 0) return;
  // Marker so the app knows this background wake is a pairing nudge (it pulls).
  const data = { type: "pair" };
  for (const t of tokens) {
    await sendBackgroundPush(config, t.token, t.env, nowSec, data);
  }
}
