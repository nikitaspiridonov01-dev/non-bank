// Decrypts the receipt-items ciphertext that the iOS client uploaded
// via `POST /v1/share-items/{checksum}`. Same key-derivation +
// AES-GCM bundle layout as iOS-side `ShareItemsCrypto`, just
// re-implemented against Web Crypto so the Worker can render items
// in the `/share` HTML preview when a recipient opens the link in a
// browser.
//
// Symmetry with iOS (do NOT diverge — they must agree for decrypt
// to succeed):
//   - HKDF-SHA256 derives 32 bytes from `urlPayload` (the URL's `?p`
//     query value).
//   - Salt: ASCII "non-bank-share-items-v1".
//   - Info: ASCII "items".
//   - Cipher: AES-256-GCM.
//   - Bundle layout (base64-decoded): nonce(12) ‖ ciphertext ‖ tag(16).
//     Web Crypto's AES-GCM expects `iv` separately and treats the
//     concatenated `ciphertext ‖ tag` as one buffer — split at byte 12.
//
// Anyone with the URL can derive the key. The Worker has the URL on
// every `/share?p=…` request, so it CAN decrypt — but it can't
// produce ciphertext (no sender-side key exfiltration via this
// endpoint), and it never logs the plaintext.

/// Compact wire shape — single-letter keys to keep the ciphertext
/// payload small. Mirrors iOS `ShareItemsCrypto.WireItem` exactly.
export interface WireItem {
  /** name */
  n: string;
  /** quantity */
  q?: number | null;
  /** unit price */
  p?: number | null;
  /** line total */
  t?: number | null;
  /** assigned participant IDs (sender's local identity space —
   *  recipients translate on the iOS side via
   *  `ReceivedTransactionMapper.rewriteItemAssignees`; the web
   *  preview just renders the names + amounts and doesn't surface
   *  the per-participant assignment table). */
  a?: string[];
}

const HKDF_SALT = new TextEncoder().encode("non-bank-share-items-v1");
const HKDF_INFO = new TextEncoder().encode("items");
const AES_NONCE_BYTES = 12;

/// Returns the decrypted items, or `null` if anything went wrong —
/// invalid base64, malformed bundle, wrong key (auth-tag mismatch),
/// or unparseable plaintext. The caller treats `null` as "no items
/// to show" and silently falls back to the receipt-items-omitted
/// rendering that existed before this feature shipped.
export async function decryptShareItems(
  base64Ciphertext: string,
  urlPayload: string,
): Promise<WireItem[] | null> {
  try {
    const combined = base64ToBytes(base64Ciphertext);
    if (combined.byteLength <= AES_NONCE_BYTES) return null;
    const nonce = combined.slice(0, AES_NONCE_BYTES);
    const ciphertextWithTag = combined.slice(AES_NONCE_BYTES);

    const baseKey = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(urlPayload),
      { name: "HKDF" },
      false,
      ["deriveKey"],
    );
    const derivedKey = await crypto.subtle.deriveKey(
      {
        name: "HKDF",
        hash: "SHA-256",
        salt: HKDF_SALT,
        info: HKDF_INFO,
      },
      baseKey,
      { name: "AES-GCM", length: 256 },
      false,
      ["decrypt"],
    );

    const plaintextBuffer = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce },
      derivedKey,
      ciphertextWithTag,
    );
    const json = new TextDecoder().decode(plaintextBuffer);
    const parsed = JSON.parse(json);
    if (!Array.isArray(parsed)) return null;
    // Surface only items with the required `n` field. Defensive —
    // upstream encoder always emits a name.
    return parsed.filter(
      (it): it is WireItem => typeof it === "object" && it !== null && typeof it.n === "string",
    );
  } catch {
    return null;
  }
}

/// Compute the payload's SHA-256 checksum (hex) — same digest the
/// iOS encoder uses as the `share_items` row key. The input is the
/// raw JSON bytes that came out of base64url-decoding the URL's
/// `?p=` value: iOS encodes the payload with `outputFormatting:
/// [.sortedKeys, .withoutEscapingSlashes]`, then base64urls those
/// exact bytes, so re-hashing the decoded bytes yields the same
/// checksum the sender uploaded the items under.
export async function payloadChecksumFromJSONString(json: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(json),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
