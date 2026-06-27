// Static landing / home page served at GET / (the brand root).
//
// non-bank.app/ previously had no handler and fell through to the JSON 404 — a
// raw error on the brand domain. This is a compact home page: what the app is,
// a download CTA, a few value props, and links to Privacy + Support. Fully
// static, same warm dark/light palette as /privacy and /support so the site
// reads as one product. Usable as the App Store "Marketing URL".

const SUPPORT_EMAIL = "nonbankapp@gmail.com";
// App Store URL (App Store Connect Apple ID). Resolves once the app is live.
const APP_STORE_URL = "https://apps.apple.com/app/id6771929105";

export function handleLandingPage(): Response {
  return new Response(LANDING_HTML, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=3600",
    },
  });
}

const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Non Bank · private expense tracker & bill splitter</title>
<meta name="description" content="Non Bank is a private expense tracker and bill splitter for iPhone. No bank logins, no ads, no data selling.">
<meta name="theme-color" content="#0a0807">
<meta name="robots" content="index, follow">
<style>
  :root {
    color-scheme: dark light;
    --bg: #0a0807;
    --surface: #1a1614;
    --surface-elevated: #221c19;
    --text: #f4ede4;
    --text-secondary: #b8a695;
    --text-tertiary: #8a8076;
    --border: #2a2421;
    --accent: #c8afe1;
    --warm-cta: #c79566;
    --cta-bg: #97632c;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f7f3ee;
      --surface: #ffffff;
      --surface-elevated: #fbf6ef;
      --text: #1c1816;
      --text-secondary: #6b5d4f;
      --text-tertiary: #8a8076;
      --border: #efe7dc;
      --accent: #6E46B4;
      --warm-cta: #8a5520;
      --cta-bg: #8a5520;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    line-height: 1.6;
  }
  .page { max-width: 680px; margin: 0 auto; padding: 72px 22px 72px; }
  .eyebrow { font-size: 13px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--accent); margin-bottom: 14px; }
  h1 { font-size: 36px; font-weight: 700; letter-spacing: -0.8px; line-height: 1.15; margin-bottom: 16px; }
  .lede { font-size: 18px; color: var(--text-secondary); max-width: 540px; margin-bottom: 28px; }
  .cta-row { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 56px; }
  .cta {
    display: inline-block;
    background: var(--cta-bg);
    color: #fff;
    font-size: 16px;
    font-weight: 600;
    padding: 13px 22px;
    border-radius: 12px;
    text-decoration: none;
  }
  .cta:hover { text-decoration: none; opacity: 0.92; }
  .cta.secondary { background: transparent; color: var(--accent); border: 1px solid var(--border); }
  .features { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
  .feature {
    background: var(--surface-elevated);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 20px 22px;
  }
  .feature h2 { font-size: 16px; font-weight: 700; margin-bottom: 6px; letter-spacing: -0.2px; }
  .feature p { font-size: 14px; color: var(--text-secondary); }
  footer { margin-top: 52px; padding-top: 24px; border-top: 1px solid var(--border); font-size: 13px; color: var(--text-tertiary); }
  footer a { color: var(--warm-cta); }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
</style>
</head>
<body>
  <div class="page">
    <div class="eyebrow">Non Bank</div>
    <h1>Track your money. Split with friends. Privately.</h1>
    <p class="lede">A private expense tracker and bill splitter for iPhone — no bank logins, no ads, no data selling.</p>

    <div class="cta-row">
      <a class="cta" href="${APP_STORE_URL}" rel="noopener">Get the app</a>
      <a class="cta secondary" href="/support">Support</a>
    </div>

    <div class="features">
      <div class="feature">
        <h2>Private by design</h2>
        <p>Your transactions, friends and receipts stay on your device and sync only to your own iCloud. We never see them.</p>
      </div>
      <div class="feature">
        <h2>Split any bill</h2>
        <p>Evenly, by exact amounts, or item by item. Scan a receipt and split it line by line.</p>
      </div>
      <div class="feature">
        <h2>Synced with friends</h2>
        <p>Share a split and your friend's copy updates automatically — encrypted, so it stays between you.</p>
      </div>
      <div class="feature">
        <h2>See where it goes</h2>
        <p>Clear insights, recurring reminders and multiple currencies — the whole picture, at a glance.</p>
      </div>
    </div>

    <footer>
      Non Bank · <a href="/privacy">Privacy</a> · <a href="/support">Support</a> · <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
    </footer>
  </div>
</body>
</html>`;
