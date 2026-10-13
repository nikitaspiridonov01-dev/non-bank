// Static landing / home page served at GET / (the brand root).
//
// non-bank.app/ previously had no handler and fell through to the JSON 404 — a
// raw error on the brand domain. This is the home page: what the app is, a
// download CTA, how it works, value props, who it is for, and an FAQ. Fully
// static, same warm dark/light palette as /privacy and /support so the site
// reads as one product. Usable as the App Store "Marketing URL".
//
// The copy is written for the queries people actually type when they look for
// an app like this ("split bill by receipt", "private expense tracker",
// "scan receipt split with friends"); the shared <head> (canonical, Open Graph,
// JSON-LD, sitemap) lives in `seo.ts`. Keep the FAQ text and the FAQPage
// JSON-LD below in sync — they are the same answers.

import { seoHead, APP_STORE_URL, SUPPORT_EMAIL } from "./seo.ts";

export function handleLandingPage(): Response {
  return new Response(LANDING_HTML, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=3600",
    },
  });
}

const FAQ: ReadonlyArray<{ q: string; a: string }> = [
  {
    q: "Does Non Bank connect to my bank account?",
    a: "No. Non Bank never asks for bank logins. You add expenses yourself, scan receipts, or import a CSV or Excel file. That is what keeps it private: there is nothing to connect and nothing to leak.",
  },
  {
    q: "How does splitting a receipt by item work?",
    a: "Scan the receipt with the camera. Non Bank reads each line, you tap who had what, and it works out every person's share, including shared items, tax and tip.",
  },
  {
    q: "Do my friends need the app?",
    a: "Splitting works without it. You can share a split as a link so a friend sees their share. If they also install Non Bank, their copy updates automatically and stays encrypted end to end.",
  },
  {
    q: "Where is my data stored?",
    a: "On your iPhone, and in your own iCloud if you turn sync on. We run no account system and cannot see your transactions, friends or receipts. Receipt images are processed transiently and not kept.",
  },
  {
    q: "Is Non Bank free?",
    a: "Yes. There are no ads and no subscription. If it saves you time, you can leave a tip inside the app.",
  },
  {
    q: "Can I export my data?",
    a: "Any time, as CSV or JSON, from Settings. Your data is yours.",
  },
];

const faqJsonLd = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: FAQ.map((f) => ({
    "@type": "Question",
    name: f.q,
    acceptedAnswer: { "@type": "Answer", text: f.a },
  })),
};

const HEAD = seoHead({
  path: "/",
  title: "Non Bank – Expense Tracker & Bill Splitter for iPhone",
  description:
    "Scan a receipt and split it item by item, track spending and settle up with friends. No bank login, no account, no ads — your data stays on your iPhone.",
  jsonLd: [faqJsonLd],
});

const faqHtml = FAQ.map(
  (f) => `      <details>
        <summary>${f.q}</summary>
        <p>${f.a}</p>
      </details>`,
).join("\n");

const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
${HEAD}
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
  section { margin-top: 56px; }
  section h2 { font-size: 22px; font-weight: 700; letter-spacing: -0.3px; margin-bottom: 14px; }
  section p { color: var(--text-secondary); margin-bottom: 12px; }
  .steps { counter-reset: step; display: grid; gap: 12px; }
  .step { display: flex; gap: 14px; background: var(--surface-elevated); border: 1px solid var(--border); border-radius: 16px; padding: 16px 18px; }
  .step::before { counter-increment: step; content: counter(step); flex: 0 0 30px; height: 30px; border-radius: 50%; background: var(--cta-bg); color: #fff; font-weight: 700; display: flex; align-items: center; justify-content: center; font-size: 14px; }
  .step h3 { font-size: 15px; font-weight: 700; margin-bottom: 4px; }
  .step p { font-size: 14px; margin: 0; }
  .uses { display: flex; flex-wrap: wrap; gap: 8px; }
  .uses span { font-size: 13px; padding: 6px 12px; border-radius: 999px; border: 1px solid var(--border); color: var(--text-secondary); }
  .faq details { border-top: 1px solid var(--border); padding: 12px 0; }
  .faq details:last-child { border-bottom: 1px solid var(--border); }
  .faq summary { cursor: pointer; font-weight: 600; font-size: 15px; list-style: none; }
  .faq summary::-webkit-details-marker { display: none; }
  .faq summary::after { content: "+"; float: right; color: var(--text-tertiary); }
  .faq details[open] summary::after { content: "–"; }
  .faq p { font-size: 14px; margin: 8px 0 0; }
</style>
</head>
<body>
  <div class="page">
    <div class="eyebrow">Non Bank for iPhone</div>
    <h1>Split bills by receipt. Track your money. Privately.</h1>
    <p class="lede">Non Bank is a private expense tracker and bill splitter. Scan a receipt, split it item by item with friends, and see where your money goes — with no bank login, no account and no ads.</p>

    <div class="cta-row">
      <a class="cta" href="${APP_STORE_URL}" rel="noopener">Get it free on the App Store</a>
      <a class="cta secondary" href="/support">Support</a>
    </div>

    <section>
      <h2>How it works</h2>
      <div class="steps">
        <div class="step">
          <div>
            <h3>Scan the receipt</h3>
            <p>Point the camera at a restaurant bill, a grocery receipt or a hotel invoice. Non Bank reads every line and the total.</p>
          </div>
        </div>
        <div class="step">
          <div>
            <h3>Tap who had what</h3>
            <p>Assign items to friends, share the ones you split, add tax and tip. Or skip the receipt and split evenly or by exact amounts.</p>
          </div>
        </div>
        <div class="step">
          <div>
            <h3>Settle up in one tap</h3>
            <p>Each friend has a running balance of who owes whom, netted across every dinner and trip. Mark it settled when the money moves.</p>
          </div>
        </div>
      </div>
    </section>

    <section>
      <h2>Why Non Bank</h2>
      <div class="features">
        <div class="feature">
          <h2>Private by design</h2>
          <p>Your transactions, friends and receipts stay on your device and sync only to your own iCloud. There is no account to create and nothing for us to see.</p>
        </div>
        <div class="feature">
          <h2>Split any bill</h2>
          <p>Evenly, by exact amounts, or item by item from a scanned receipt. Multiple currencies, converted at the day's rate.</p>
        </div>
        <div class="feature">
          <h2>Synced with friends</h2>
          <p>Share a split and your friend's copy updates automatically — encrypted end to end, so it stays between you.</p>
        </div>
        <div class="feature">
          <h2>See where it goes</h2>
          <p>Expenses and income with your own categories and emoji, clear monthly insights, recurring transactions and reminders.</p>
        </div>
      </div>
    </section>

    <section>
      <h2>Made for shared money</h2>
      <p>Non Bank is for people who split costs with the same friends again and again, and who do not want to hand a bank login to an app to do it.</p>
      <div class="uses">
        <span>Group trips</span><span>Roommates and rent</span><span>Dinners out</span><span>Couples' budgets</span><span>Road trips</span><span>Weekend getaways</span><span>Shared groceries</span>
      </div>
    </section>

    <section class="faq">
      <h2>Questions</h2>
${faqHtml}
    </section>

    <footer>
      Non Bank · <a href="/privacy">Privacy Policy</a> · <a href="/support">Support</a> · <a href="${APP_STORE_URL}" rel="noopener">App Store</a> · <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
    </footer>
  </div>
</body>
</html>`;
