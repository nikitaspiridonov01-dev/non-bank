// Static support page served at GET /support.
//
// Required for the App Store "Support URL" field (Apple needs a reachable
// page where users can get help / contact support). Fully static — no user
// input reaches this page, so nothing here needs escaping. Styled with the
// same warm dark/light palette as the privacy + share pages so the three
// read as one product.

const SUPPORT_EMAIL = "nonbankapp@gmail.com";
// App Store URL for the "Get the app" button (App Store Connect Apple ID).
// Resolves once the app is live; before that it 404s, which is fine — the
// Support URL page itself is what App Review needs to load.
const APP_STORE_URL = "https://apps.apple.com/app/id6771929105";

export function handleSupportPage(): Response {
  return new Response(SUPPORT_HTML, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // Cache at the edge for an hour — static page, keeps Worker invocations down.
      "Cache-Control": "public, max-age=3600",
    },
  });
}

const SUPPORT_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Support · Non Bank</title>
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
  .page { max-width: 680px; margin: 0 auto; padding: 56px 22px 72px; }
  header { margin-bottom: 36px; }
  .eyebrow { font-size: 13px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--accent); margin-bottom: 10px; }
  h1 { font-size: 30px; font-weight: 700; letter-spacing: -0.5px; margin-bottom: 8px; }
  .lede { font-size: 16px; color: var(--text-secondary); }
  .cta-row { display: flex; flex-wrap: wrap; gap: 12px; margin: 8px 0 36px; }
  .cta {
    display: inline-block;
    background: var(--cta-bg);
    color: #fff;
    font-size: 15px;
    font-weight: 600;
    padding: 12px 20px;
    border-radius: 12px;
    text-decoration: none;
  }
  .cta:hover { text-decoration: none; opacity: 0.92; }
  .cta.secondary { background: transparent; color: var(--accent); border: 1px solid var(--border); }
  section { margin-bottom: 30px; }
  h2 { font-size: 19px; font-weight: 700; margin-bottom: 10px; letter-spacing: -0.2px; }
  .faq-q { font-size: 16px; font-weight: 600; color: var(--text); margin: 18px 0 4px; }
  p { font-size: 15px; color: var(--text-secondary); margin-bottom: 10px; }
  p b { color: var(--text); font-weight: 600; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .contact {
    background: var(--surface-elevated);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 20px 22px;
    margin-bottom: 36px;
  }
  .contact h2 { margin-bottom: 6px; }
  .contact .email { font-size: 17px; font-weight: 600; }
  footer { margin-top: 44px; padding-top: 24px; border-top: 1px solid var(--border); font-size: 13px; color: var(--text-tertiary); }
  footer a { color: var(--warm-cta); }
</style>
</head>
<body>
  <div class="page">
    <header>
      <div class="eyebrow">Non Bank</div>
      <h1>Support</h1>
      <p class="lede">Non Bank is a private expense tracker and bill splitter for iPhone. Need a hand? You're in the right place.</p>
    </header>

    <div class="cta-row">
      <a class="cta" href="${APP_STORE_URL}" rel="noopener">Get the app</a>
      <a class="cta secondary" href="/privacy">Privacy Policy</a>
    </div>

    <div class="contact">
      <h2>Contact us</h2>
      <p>Questions, bugs, or feedback? Email us and we'll get back to you.</p>
      <p class="email"><a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
    </div>

    <section>
      <h2>Frequently asked questions</h2>

      <p class="faq-q">Is my financial data private?</p>
      <p>Yes. Your transactions, friends, categories and receipts live <b>on your device</b> and sync through <b>your own iCloud</b> — we can't see them. No ads, no cross-app tracking, no selling your data. A split you share is end-to-end encrypted. See our <a href="/privacy">Privacy Policy</a> for the full details.</p>

      <p class="faq-q">How do I sync across my devices?</p>
      <p>Sign in to the <b>same iCloud account</b> on each device and keep iCloud sync enabled. Your data is carried by Apple's iCloud (CloudKit), which only you can access. Restoring on a new iPhone works the same way — sign in to your iCloud account.</p>

      <p class="faq-q">How do I split a bill?</p>
      <p>Add an expense, choose how to split it — <b>evenly</b>, <b>by exact amounts</b>, or <b>item by item</b> — and pick the friends involved. Non Bank keeps a running balance of who owes whom.</p>

      <p class="faq-q">How do I share a split with a friend?</p>
      <p>Open the split and share it. Your friend gets a link; if you're both on Non Bank, their copy stays in sync automatically, and any edits flow between you — encrypted, so only the two of you can read them.</p>

      <p class="faq-q">How do I scan a receipt?</p>
      <p>Tap to scan a receipt photo and Non Bank pulls out the items, prices, taxes and fees. You can adjust anything by hand before saving. The photo is processed to read the receipt and is not stored.</p>

      <p class="faq-q">How do I delete my data?</p>
      <p>Deleting the app removes all on-device data. Data stored in your iCloud can be removed from your device's iCloud settings.</p>
    </section>

    <footer>
      Non Bank · private split tracker · <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> · <a href="/privacy">Privacy</a>
    </footer>
  </div>
</body>
</html>`;
