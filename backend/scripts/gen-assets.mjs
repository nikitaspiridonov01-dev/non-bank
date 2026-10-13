#!/usr/bin/env node
// Regenerates src/site_assets.ts: renders scripts/og-card.html to a 1200×630
// PNG with headless Chromium and embeds it + scripts/icon.png as base64.
//
//   node scripts/gen-assets.mjs            # uses `chromium` / `google-chrome` on PATH
//   CHROME=/path/to/chrome node scripts/gen-assets.mjs
//
// The icon is a copy of the iOS AppIcon-1024.png; re-copy it here when the
// app icon changes.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const chrome =
  process.env.CHROME ??
  ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"].find((c) => {
    try {
      execFileSync("which", [c], { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  });
if (!chrome) {
  console.error("No Chromium found. Set CHROME=/path/to/chrome.");
  process.exit(1);
}

const out = join(mkdtempSync(join(tmpdir(), "og-")), "og.png");
execFileSync(chrome, [
  "--headless",
  "--no-sandbox",
  "--disable-gpu",
  "--hide-scrollbars",
  "--force-device-scale-factor=1",
  "--window-size=1200,630",
  `--screenshot=${out}`,
  `file://${join(here, "og-card.html")}`,
], { stdio: "ignore" });

const chunk = (b64) =>
  b64.match(/.{1,120}/g).join('" +\n  "');
const og = readFileSync(out).toString("base64");
const icon = readFileSync(join(here, "icon.png")).toString("base64");

writeFileSync(
  join(here, "..", "src", "site_assets.ts"),
  `// GENERATED FILE — do not edit by hand.
//
// Binary assets for the public site, embedded as base64 so the Worker needs no
// static-asset binding. Regenerate with \`node scripts/gen-assets.mjs\` after
// changing the icon or the Open Graph card template (see scripts/og-card.html).
//
//   OG_PNG_B64   — 1200×630 link-preview card (og:image / twitter:image)
//   ICON_PNG_B64 — 1024×1024 app icon (favicon, apple-touch-icon, JSON-LD image)

export const OG_PNG_B64 =
  "${chunk(og)}";

export const ICON_PNG_B64 =
  "${chunk(icon)}";
`,
);
console.log(`wrote src/site_assets.ts (og ${og.length} b64 chars, icon ${icon.length})`);
