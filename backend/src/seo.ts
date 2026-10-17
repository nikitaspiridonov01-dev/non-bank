// Search-engine + link-preview plumbing for the public site (non-bank.app).
//
// Before this module the site had no robots.txt, no sitemap, no canonical
// URLs, no Open Graph / Twitter cards and no structured data, and Google had
// not indexed a single page. Everything here is static: the Worker has no
// asset binding, so the two images are served from base64 constants in
// `site_assets.ts` (regenerate with `node scripts/gen-assets.mjs`).
//
// Exports:
//   seoHead(page)        — the <head> fragment every HTML page shares
//   handleRobots()       — GET /robots.txt
//   handleSitemap()      — GET /sitemap.xml
//   handleOgImage()      — GET /og.png            (1200×630 link-preview card)
//   handleIcon()         — GET /icon.png, /apple-touch-icon.png, /favicon.ico
//   handleSiteFile(path) — GET /<IndexNow key>.txt and Google's verification
//                          file; returns null for any other path

import { OG_PNG_B64, ICON_PNG_B64 } from "./site_assets.ts";

export const SITE_URL = "https://non-bank.app";
export const APP_NAME = "Non Bank";
export const APP_STORE_ID = "6771929105";
export const APP_STORE_URL = `https://apps.apple.com/app/id${APP_STORE_ID}`;
export const SUPPORT_EMAIL = "nonbankapp@gmail.com";

/** Public HTML pages, in sitemap order. `lastmod` is bumped by hand when a
 *  page's content changes materially (search engines treat it as a hint). */
export const SITE_PAGES: ReadonlyArray<{ path: string; lastmod: string; priority: string }> = [
  { path: "/", lastmod: "2026-10-13", priority: "1.0" },
  { path: "/support", lastmod: "2026-10-13", priority: "0.6" },
  { path: "/privacy", lastmod: "2026-10-13", priority: "0.4" },
];

export interface SeoPage {
  /** Path of the page, e.g. "/" or "/support". Used for the canonical URL. */
  path: string;
  /** <title> text, ≤ 60 chars so it is not truncated in results. */
  title: string;
  /** Meta description, ≤ 155 chars. */
  description: string;
  /** Extra JSON-LD objects to emit alongside the shared SoftwareApplication. */
  jsonLd?: ReadonlyArray<Record<string, unknown>>;
}

/** Structured data describing the app itself. Shared by every page so a
 *  crawler landing anywhere learns the same facts: name, platform, price,
 *  where to install, who to contact. */
export function appJsonLd(): Record<string, unknown> {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: `${APP_NAME}: Expense & Bill Split`,
    alternateName: APP_NAME,
    applicationCategory: "FinanceApplication",
    operatingSystem: "iOS",
    url: SITE_URL + "/",
    installUrl: APP_STORE_URL,
    downloadUrl: APP_STORE_URL,
    image: `${SITE_URL}/icon.png`,
    description:
      "Private expense tracker and bill splitter for iPhone. Scan a receipt and split it item by item, keep a running balance with friends, and settle up in one tap. No bank login, no account, no ads.",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    featureList: [
      "Scan a receipt and split it line by line",
      "Split bills evenly, by exact amounts, or item by item",
      "Running balance of who owes whom, settle up in one tap",
      "Share a split with a friend, end-to-end encrypted",
      "Expense and income tracking with categories and insights",
      "Multiple currencies, recurring transactions, reminders",
      "Data stays on your iPhone and your own iCloud",
    ],
    author: { "@type": "Organization", name: APP_NAME, url: SITE_URL + "/", email: SUPPORT_EMAIL },
  };
}

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** JSON inside <script type="application/ld+json"> must not be able to close
 *  the script element; escaping `<` is the standard guard. */
function jsonForScript(v: unknown): string {
  return JSON.stringify(v).replace(/</g, "\\u003c");
}

/** The shared <head> fragment: title, description, canonical, robots, icons,
 *  Open Graph + Twitter cards, the Safari Smart App Banner, and JSON-LD. */
export function seoHead(page: SeoPage): string {
  const canonical = SITE_URL + page.path;
  const ld = [appJsonLd(), ...(page.jsonLd ?? [])];
  return [
    `<meta charset="UTF-8">`,
    `<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">`,
    `<title>${esc(page.title)}</title>`,
    `<meta name="description" content="${esc(page.description)}">`,
    `<link rel="canonical" href="${canonical}">`,
    `<meta name="robots" content="index, follow, max-image-preview:large">`,
    `<meta name="theme-color" content="#0a0807">`,
    `<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}">`,
    `<link rel="icon" type="image/png" sizes="1024x1024" href="/icon.png">`,
    `<link rel="apple-touch-icon" href="/apple-touch-icon.png">`,
    `<meta property="og:type" content="website">`,
    `<meta property="og:site_name" content="${APP_NAME}">`,
    `<meta property="og:url" content="${canonical}">`,
    `<meta property="og:title" content="${esc(page.title)}">`,
    `<meta property="og:description" content="${esc(page.description)}">`,
    `<meta property="og:image" content="${SITE_URL}/og.png">`,
    `<meta property="og:image:width" content="1200">`,
    `<meta property="og:image:height" content="630">`,
    `<meta property="og:image:alt" content="${APP_NAME}: scan a receipt, split it item by item">`,
    `<meta property="og:locale" content="en_US">`,
    `<meta name="twitter:card" content="summary_large_image">`,
    `<meta name="twitter:title" content="${esc(page.title)}">`,
    `<meta name="twitter:description" content="${esc(page.description)}">`,
    `<meta name="twitter:image" content="${SITE_URL}/og.png">`,
    `<script type="application/ld+json">${jsonForScript(ld.length === 1 ? ld[0] : ld)}</script>`,
  ].join("\n");
}

const TEXT_CACHE = "public, max-age=86400";
// Images change only with a deploy; a day at the edge keeps Worker invocations
// down, and link scrapers re-fetch on their own schedule anyway.
const IMAGE_CACHE = "public, max-age=86400";

export function handleRobots(): Response {
  const body = [
    "User-agent: *",
    "Allow: /",
    // API + share links carry nothing a search engine should index: the
    // share page is per-recipient and the API is JSON.
    "Disallow: /v1/",
    "Disallow: /share",
    "",
    `Sitemap: ${SITE_URL}/sitemap.xml`,
    "",
  ].join("\n");
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": TEXT_CACHE },
  });
}

export function handleSitemap(): Response {
  const urls = SITE_PAGES.map(
    (p) =>
      `  <url><loc>${SITE_URL}${p.path}</loc><lastmod>${p.lastmod}</lastmod><priority>${p.priority}</priority></url>`,
  ).join("\n");
  const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": TEXT_CACHE },
  });
}

function pngResponse(b64: string): Response {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Response(bytes, {
    status: 200,
    headers: { "Content-Type": "image/png", "Cache-Control": IMAGE_CACHE },
  });
}

export function handleOgImage(): Response {
  return pngResponse(OG_PNG_B64);
}

export function handleIcon(): Response {
  return pngResponse(ICON_PNG_B64);
}

/** IndexNow key (https://www.indexnow.org). Public by design: search engines
 *  fetch `/<key>.txt` to confirm a submission came from the site owner. Used
 *  by `.github/scripts/indexnow.py` to push URLs to Bing, Yandex, Seznam, Naver. */
export const INDEXNOW_KEY = "3e18e1e9475715331eba86967071f0ff";

/** Google Search Console HTML-file verification tokens (one per verified
 *  owner). Public by design: Google fetches the file to confirm ownership,
 *  and removing it un-verifies that owner. */
export const GOOGLE_VERIFICATION_FILES: ReadonlyArray<string> = [
  "googleb9b14a1f82881a17.html", // ga4-reader@non-bank-69eb0 service account (Search Console API)
];

/** Small public text files that prove site ownership to search engines. */
export function handleSiteFile(path: string): Response | null {
  const name = path.replace(/^\//, "");
  if (name === `${INDEXNOW_KEY}.txt`) {
    return new Response(INDEXNOW_KEY, {
      status: 200,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": TEXT_CACHE },
    });
  }
  if (GOOGLE_VERIFICATION_FILES.includes(name)) {
    return new Response(`google-site-verification: ${name}`, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" },
    });
  }
  return null;
}
