// Static privacy-policy page served at GET /privacy.
//
// Required for App Store / TestFlight external testing (the "Privacy
// Policy URL" field). The content reflects exactly what the app does —
// see the app's PrivacyInfo.xcprivacy: first-party analytics only, no
// tracking, receipts processed transiently, all financial data on-device
// + the user's own iCloud.
//
// Fully static — no user input reaches this page, so nothing here needs
// escaping. Styled with the same warm dark/light palette as the share
// landing page so the two read as one product.

const SUPPORT_EMAIL = "nonbankapp@gmail.com";
const LAST_UPDATED = "28 June 2026";

export function handlePrivacyPage(): Response {
  return new Response(PRIVACY_HTML, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // Cache at the edge for an hour — the policy changes rarely and the
      // page is static, so this keeps Worker invocations down.
      "Cache-Control": "public, max-age=3600",
    },
  });
}

const PRIVACY_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Privacy Policy · Non Bank</title>
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
  .updated { font-size: 13px; color: var(--text-tertiary); }
  .summary {
    background: var(--surface-elevated);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 20px 22px;
    margin-bottom: 36px;
  }
  .summary h2 { font-size: 15px; margin-bottom: 12px; }
  .summary ul { list-style: none; display: flex; flex-direction: column; gap: 10px; }
  .summary li { position: relative; padding-left: 26px; font-size: 15px; color: var(--text-secondary); }
  .summary li::before { content: "✓"; position: absolute; left: 0; top: 0; color: var(--accent); font-weight: 700; }
  .summary li b { color: var(--text); font-weight: 600; }
  section { margin-bottom: 30px; }
  h2 { font-size: 19px; font-weight: 700; margin-bottom: 10px; letter-spacing: -0.2px; }
  p { font-size: 15px; color: var(--text-secondary); margin-bottom: 10px; }
  p b { color: var(--text); font-weight: 600; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  ul.body-list { list-style: disc; padding-left: 22px; margin: 4px 0 10px; }
  ul.body-list li { font-size: 15px; color: var(--text-secondary); margin-bottom: 6px; }
  footer { margin-top: 44px; padding-top: 24px; border-top: 1px solid var(--border); font-size: 13px; color: var(--text-tertiary); }
  footer a { color: var(--warm-cta); }
</style>
</head>
<body>
  <div class="page">
    <header>
      <div class="eyebrow">Non Bank</div>
      <h1>Privacy Policy</h1>
      <div class="updated">Last updated: ${LAST_UPDATED}</div>
    </header>

    <div class="summary">
      <h2>The short version</h2>
      <ul>
        <li>Your transactions, friends, categories and receipts live <b>on your device</b> and sync through <b>your own iCloud</b> — we can't see them.</li>
        <li>The only data that reaches our server is a <b>receipt you scan</b> (read, then discarded) and a <b>split you share</b> (end-to-end encrypted, briefly stored, then auto-deleted — we can't read it). Never your wider financial history.</li>
        <li>We don't <b>sell your data</b> or show <b>ads</b>, and we don't <b>track you across other apps or websites</b>. We use only <b>anonymous, first-party analytics</b> to improve the app.</li>
      </ul>
    </div>

    <section>
      <h2>Who we are</h2>
      <p>Non Bank is a private expense-splitting and personal-finance tracker for iPhone. We designed it to keep your financial information on your own device. This policy explains what limited data the app handles and why.</p>
    </section>

    <section>
      <h2>What stays on your device</h2>
      <p>Everything you enter — transactions, amounts, friends, categories, scanned receipts and balances — is stored <b>locally on your device</b>. If you turn on iCloud sync, it syncs through <b>your personal iCloud account</b> (Apple's CloudKit), which only you can access — <b>not</b> our servers. The only times data leaves your device for our server are when you <b>scan a receipt</b> or <b>share a split with a friend</b> (both covered below); even then we never receive your wider financial history, and shared splits are encrypted so we can't read them.</p>
    </section>

    <section>
      <h2>Receipt scanning</h2>
      <p>When you scan a receipt, the photo is sent to our scanning service — which uses a <b>third-party AI provider</b> to read the items and amounts. The image is processed <b>in the moment and is not stored</b> — once the results are returned to your device, the image is discarded. We keep no copy and do not use it for anything else.</p>
      <p>To prevent abuse of this service, we store a <b>one-way (hashed, non-reversible) device identifier</b> to enforce usage limits. It cannot be traced back to you or your device.</p>
    </section>

    <section>
      <h2>Analytics</h2>
      <p>We use <b>Google Analytics for Firebase</b> to understand, in aggregate, how the app is used — which features are popular and where people get stuck — so we can improve it. This collects:</p>
      <ul class="body-list">
        <li>App interaction events (for example, "a receipt was scanned"), with <b>no personal or financial content</b>;</li>
        <li>A Firebase-generated app-instance identifier, <b>not linked to your real identity</b>.</li>
      </ul>
      <p>We do <b>not</b> use this for advertising or cross-app tracking, the app does <b>not</b> use the advertising identifier (IDFA), and it never asks for tracking permission. This analytics data is processed by Google under <a href="https://policies.google.com/privacy" rel="noopener" target="_blank">Google's Privacy Policy</a>.</p>
    </section>

    <section>
      <h2>Sharing and syncing splits</h2>
      <p>To deliver a shared split to your friend — whether they already use Non Bank (it syncs automatically) or you send them a link — the split's details are <b>encrypted on your device first</b>, then relayed through our server. The decryption key is derived independently on each device, or carried inside the link itself; it is <b>never sent to our servers</b>, so we <b>cannot read</b> what you shared.</p>
      <p>That encrypted data is stored only <b>temporarily</b>: it's removed once your friend's device picks it up, and automatically deleted in any case after at most <b>14 days</b> (in-app sync) or <b>30 days</b> (share links). To route a split to the right device we also store an <b>opaque, hashed</b> pairing token and (for notifications) a device push token — neither reveals who you are or who your friends are, and there is no record of your social graph.</p>
    </section>

    <section>
      <h2>App integrity</h2>
      <p>To protect the receipt-scanning service from abuse, the app uses <b>Apple's App Attest</b> to confirm that requests come from a genuine, unmodified copy of the app. This involves a cryptographic key and a counter only — it contains <b>no personal data</b>.</p>
    </section>

    <section>
      <h2>No accounts</h2>
      <p>The app has <b>no user accounts</b>. We don't ask for your name, email or phone number to use it. If you email us for support, we'll only have what you choose to send.</p>
    </section>

    <section>
      <h2>Children</h2>
      <p>Non Bank is not directed at children under 13, and we do not knowingly collect data from them.</p>
    </section>

    <section>
      <h2>Your choices</h2>
      <ul class="body-list">
        <li>You can turn iCloud sync on or off at any time in the app's Settings.</li>
        <li>Deleting the app removes all on-device data; iCloud data can be removed from your iCloud settings.</li>
      </ul>
    </section>

    <section>
      <h2>Changes to this policy</h2>
      <p>We may update this policy from time to time. The "Last updated" date at the top always reflects the current version.</p>
    </section>

    <section>
      <h2>Contact</h2>
      <p>Questions about your privacy? Email us at <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>
    </section>

    <footer>
      Non Bank · private split tracker · <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
    </footer>
  </div>
</body>
</html>`;
