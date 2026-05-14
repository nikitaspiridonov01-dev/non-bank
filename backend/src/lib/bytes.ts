// Workers runtime has `btoa`/`atob` for ASCII strings only — for binary we
// build base64 manually in 8 KB chunks to stay well under the V8 string-arg
// limit even for large images.
export function toBase64(bytes: Uint8Array): string {
  const CHUNK = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK) {
    const slice = bytes.subarray(i, Math.min(i + CHUNK, bytes.length));
    binary += String.fromCharCode(...slice);
  }
  return btoa(binary);
}
