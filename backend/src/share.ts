// Share-link landing page.
//
// Renders an HTML preview of a split transaction that mirrors the iOS
// app's `TransactionDetailView` in `.debts` (split-view) source mode
// pixel-for-pixel where it can — emoji-tile header, purple two-tone
// split breakdown, pixel-cat avatars (algorithm ported from
// `PixelCatGenerator`), debts-to-settle list, recurring badge.
//
// Recipients without the iOS app see this page; recipients WITH the
// iOS app are auto-handed-off via `nonbank://share?p=…` on load.
//
// Design choices matching the conversation:
//   • Items live in the share TEXT (built by iOS UIActivityItemSource),
//     NOT in the URL. The web page therefore never tries to render
//     items. Recurring info IS in the URL — small footprint, visible
//     here as a read-only badge.
//   • For 3+-participant splits the page asks "who are you?" via a
//     picker overlay (mirrors the iOS app's WhoAreYouPickerView). The
//     choice is persisted in localStorage by participant ID, so a
//     friend who's identified themselves once never gets asked again.
//     For 2-participant splits the recipient IS the friend, so we
//     auto-pick.
//   • Tapping the Purchase / People halves of the split card opens
//     overlay sheets (slide-up modals) — same nested-screen feel the
//     iOS PaidUpfrontView / ShareDistributionView delivers, just
//     contained in a single page.

import { pixelCatSVG } from "./pixelCat.ts";

interface SharedParticipant {
  id: string;
  n: string;
  sh: number;
  pa: number;
}

// Recurring rule payload — mirrors iOS `SharedRecurring`. Only the
// fields relevant to the kind are populated.
interface SharedRecurring {
  k: "d" | "w" | "m" | "y";
  h: number;
  mn: number;
  dw?: number[];     // weekly: 1=Sun…7=Sat
  dm?: number[];     // monthly: 1…31
  mo?: number;       // yearly: 1…12
  dy?: number;       // yearly: 1…31
}

interface SharedPayload {
  v: number;
  id: string;
  s: string;
  ta: number;
  pa: number;
  ms: number;
  c: string;
  d: number;
  k: "exp" | "inc";
  t: string;
  cn?: string;
  ce?: string;
  sm?: string;
  sn?: string;
  f: SharedParticipant[];
  r?: SharedRecurring;
}

export async function handleSharePage(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const p = url.searchParams.get("p");
  if (!p) {
    return htmlResponse(errorPage("This share link is missing its payload."), 400);
  }

  let payload: SharedPayload;
  try {
    const json = base64urlDecodeToString(p);
    payload = JSON.parse(json);
  } catch {
    return htmlResponse(errorPage("This share link is malformed and can't be opened."), 400);
  }

  if (typeof payload !== "object" || payload === null || payload.v !== 1) {
    return htmlResponse(
      errorPage("This share link uses a newer format. Update non-bank to open it."),
      400,
    );
  }

  const appLink = `nonbank://share?p=${p}`;
  return htmlResponse(renderSharePage(payload, appLink), 200);
}

// ─── Domain types & math ──────────────────────────────────────────────

interface Person {
  id: string;
  name: string;
  paid: number;
  share: number;
  isSharer: boolean;
}

interface SimplifiedTransfer {
  fromName: string;
  fromId: string;
  toName: string;
  toId: string;
  amount: number;
}

function simplifyDebts(people: Person[], epsilon = 0.005): SimplifiedTransfer[] {
  const balances = people
    .map((p) => ({ id: p.id, name: p.name, balance: p.paid - p.share }))
    .filter((b) => Math.abs(b.balance) > epsilon);

  const transfers: SimplifiedTransfer[] = [];

  while (balances.length > 0) {
    balances.sort((a, b) => a.balance - b.balance);
    const debtor = balances[0];
    const creditor = balances[balances.length - 1];
    if (debtor.balance >= -epsilon || creditor.balance <= epsilon) break;

    const transfer = Math.min(-debtor.balance, creditor.balance);
    transfers.push({
      fromName: debtor.name,
      fromId: debtor.id,
      toName: creditor.name,
      toId: creditor.id,
      amount: transfer,
    });

    debtor.balance += transfer;
    creditor.balance -= transfer;

    for (let i = balances.length - 1; i >= 0; i--) {
      if (Math.abs(balances[i].balance) <= epsilon) balances.splice(i, 1);
    }
  }

  return transfers;
}

// ─── Recurring formatting (mirror of iOS RepeatInterval.displayLabel) ─

const WEEKDAY_SHORT = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTH_SHORT = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function formatRecurring(r: SharedRecurring): string {
  const time = `${pad2(r.h)}:${pad2(r.mn)}`;
  switch (r.k) {
    case "d":
      return `Every day at ${time}`;
    case "w": {
      const days = (r.dw ?? [])
        .map((d) => WEEKDAY_SHORT[d] || "")
        .filter(Boolean)
        .join(", ");
      return `Weekly on ${days || "—"} at ${time}`;
    }
    case "m": {
      const days = (r.dm ?? []).map(ordinal).join(", ");
      return `Monthly on the ${days || "—"} at ${time}`;
    }
    case "y": {
      const month = MONTH_SHORT[r.mo ?? 0] || "—";
      return `Yearly on ${month} ${r.dy ?? "—"} at ${time}`;
    }
    default:
      return "Recurring";
  }
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function ordinal(day: number): string {
  const tens = day % 100;
  if (tens >= 11 && tens <= 13) return `${day}th`;
  switch (day % 10) {
    case 1: return `${day}st`;
    case 2: return `${day}nd`;
    case 3: return `${day}rd`;
    default: return `${day}th`;
  }
}

// ─── Rendering ────────────────────────────────────────────────────────

function renderSharePage(payload: SharedPayload, appLink: string): string {
  const sharerName = (payload.sn ?? "").trim() || "Someone";
  const titleHTML = escapeHTML(payload.t || "Shared transaction");
  const categoryEmoji = payload.ce ?? "💸";
  const categoryName = payload.cn ?? "";
  const isExpense = payload.k !== "inc";
  const dateLabel = formatDate(payload.d);
  const recurringLabel = payload.r ? formatRecurring(payload.r) : null;

  const people: Person[] = [
    { id: payload.s, name: sharerName, paid: payload.pa, share: payload.ms, isSharer: true },
    ...payload.f.map((p) => ({
      id: p.id,
      name: (p.n ?? "").trim() || "Friend",
      paid: p.pa,
      share: p.sh,
      isSharer: false,
    })),
  ];

  // For 2-person splits the recipient is unambiguously the only
  // friend. Skip the picker; preset their identity. For 3+-person
  // splits, the picker shows on first load (driven by JS reading
  // localStorage). The picker can ALWAYS be reopened from the
  // perspective block via the "not me?" link, so users can swap.
  const friendsOnly = people.filter((p) => !p.isSharer);
  const autoPickedId = friendsOnly.length === 1 ? friendsOnly[0].id : null;

  // Pre-compute the "viewer-relative" block for every participant.
  // The page renders all of them in the DOM, but only the one matching
  // the chosen identity is visible at any time — JS toggles `data-viewer-id`
  // on the body to flip them. This avoids any post-load re-render
  // (no flash of "Total" before the perspective resolves).
  const perspectiveBlocksHTML = renderPerspectiveBlocks(people, payload.c);

  const transfers = simplifyDebts(people);
  const debtListHTML = transfers.length === 0
    ? `<div class="debt-row balanced"><div class="avatar settled">✓</div><div class="debt-text">Everyone is settled up</div></div>`
    : transfers.map((t) => debtRowHTML(t, payload.c)).join("\n");

  // Pixel-cat avatars — same algorithm the iOS app uses, ported in
  // `pixelCat.ts`. Generated as inline SVG so the page renders without
  // any extra HTTP requests.
  const peopleAvatarsHTML = renderPeopleAvatars(people);

  // Lists for the overlay sheets — "Paid upfront" + "Shares".
  const payerCount = people.filter((p) => p.paid > 0.005).length;
  const sharerCount = people.filter((p) => p.share > 0.005).length;
  const paidUpfrontRowsHTML = people
    .filter((p) => p.paid > 0.005)
    .map((p) => sheetParticipantRow(p, p.paid, payload.c))
    .join("\n");
  const sharesRowsHTML = people
    .filter((p) => p.share > 0.005)
    .map((p) => sheetParticipantRow(p, p.share, payload.c))
    .join("\n");
  // Mirror iOS `ShareDistributionView.splitModeLabel`: 2-person
  // 50/50 stays "50/50", anything else collapses to "Evenly".
  const splitModeLabel = (() => {
    const sm = payload.sm;
    if (sm === "50/50" && sharerCount === 2) return "50/50";
    if (sm && sm !== "50/50") return sm;
    return "Evenly";
  })();

  // Identity picker rows (rendered inside the modal). Only friends —
  // the sharer is who SENT the link, can't also be the recipient.
  const identityPickerRowsHTML = friendsOnly
    .map((p) => identityPickerRowHTML(p))
    .join("\n");

  const appStoreURL = "https://apps.apple.com/search?term=non-bank";
  const peopleCount = people.length;
  const peopleLabel = `${peopleCount} ${peopleCount === 1 ? "person" : "people"}`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${escapeHTML(sharerName)} shared a transaction · non-bank</title>
<meta name="theme-color" content="#0a0807">

<meta property="og:title" content="${escapeHTML(sharerName)} shared “${titleHTML}”">
<meta property="og:description" content="${escapeHTML(formatAmount(payload.ta, payload.c))} · open in non-bank">
<meta property="og:type" content="website">

${PAGE_STYLES}
</head>
<body data-viewer-id="${escapeAttr(autoPickedId ?? "")}" data-needs-picker="${friendsOnly.length > 1 ? "1" : "0"}">

  <!-- objectBoundingBox clipPaths reused by the two split-card halves.
       Curve depth is 8% of each section's height — proportional match
       to iOS archDepth=8 on the typical ~100pt-tall section. -->
  <svg width="0" height="0" aria-hidden="true" style="position:absolute">
    <defs>
      <clipPath id="topArch" clipPathUnits="objectBoundingBox">
        <path d="M 0 0 H 1 V 1 Q 0.5 0.84 0 1 Z" />
      </clipPath>
      <clipPath id="bottomArch" clipPathUnits="objectBoundingBox">
        <path d="M 0 0.08 Q 0.5 -0.08 1 0.08 V 1 H 0 Z" />
      </clipPath>
    </defs>
  </svg>

  <script>
    // iOS auto-redirect — first visit only. If the app is installed
    // Safari hands off and this body never paints; if not, we render
    // the page and the recipient sees the preview.
    (function() {
      try {
        var ua = navigator.userAgent || "";
        if (!/iPad|iPhone|iPod/.test(ua)) return;
        var key = "nonbank-tried-redirect-${escapeJSString(payload.id)}";
        if (sessionStorage.getItem(key)) return;
        sessionStorage.setItem(key, "1");
        window.location.href = ${JSON.stringify(appLink)};
      } catch (e) {}
    })();
  </script>

  <!-- Banner above the card — sharer attribution stays visible
       independent of the transaction details below. Mirrors the
       iOS detail card's leading "from <name>" cue, but elevated
       to its own row at the very top. -->
  <div class="banner">
    <span><b>${escapeHTML(sharerName)}</b> shared a ${isExpense ? "split expense" : "split income"} with you</span>
    <button type="button" class="viewer-tag" data-action="open-picker" aria-label="Change identity">
      <span class="vt-avatar" id="viewerAvatar"></span>
      <span>Viewing as <span class="vt-name" id="viewerName">—</span></span>
    </button>
  </div>

  <!-- Hidden source-of-truth for viewer-id → (name, avatarSVG) lookups
       used by JS to populate the viewer indicator. Pre-rendering the
       SVGs server-side avoids a JS port of pixelCat just for one
       avatar swap. -->
  <script type="application/json" id="viewerIndex">${escapeJSScript(JSON.stringify(buildViewerIndex(people)))}</script>

  <div class="page">
    <header class="header">
      <div class="emoji-tile">${escapeHTML(categoryEmoji)}</div>
      <div class="title-block">
        <h1>${titleHTML}</h1>
        ${categoryName ? `<div class="category">${escapeHTML(categoryName)}</div>` : ""}
        ${recurringLabel ? `<div class="recurring"><span aria-hidden="true">🔁</span> ${escapeHTML(recurringLabel)}</div>` : ""}
      </div>
    </header>

    <!-- Perspective block: shows "You lent X" or "You borrow Y" once
         identity is chosen. If 3+ people and no choice yet, the
         "Tap who you are" prompt is shown instead. JS swaps which
         child is visible by setting [data-viewer-id] on body. -->
    <div class="perspective">
      ${perspectiveBlocksHTML}
    </div>

    <!-- Two-tone split card — concave/convex shapes match iOS
         TopArchShape / BottomArchShape. Both halves are buttons
         that open the corresponding overlay sheet. -->
    <div class="split-card">
      <button type="button" class="split-section purchase" data-target="paidUpfrontSheet" aria-label="Show paid-upfront breakdown">
        <span class="split-amount">
          <span class="int">${escapeHTML(formatAmountInteger(payload.ta))}</span>
          <span class="dec">${escapeHTML(formatAmountDecimal(payload.ta))}</span>
          <span class="cur">${escapeHTML(payload.c)}</span>
        </span>
        <span class="split-label">Purchase amount <span aria-hidden="true">↗</span></span>
      </button>
      <button type="button" class="split-section people" data-target="sharesSheet" aria-label="Show share breakdown">
        ${peopleAvatarsHTML}
        <span class="split-label">${peopleLabel} <span aria-hidden="true">↗</span></span>
      </button>
    </div>

    <div class="formula">
      <span><span class="dot purchase"></span>Purchase amount</span>
      <span class="op">÷</span>
      <span><span class="dot people"></span>${peopleLabel}</span>
      <span class="op">=</span>
      <span>Debts to settle up</span>
    </div>

    <div class="section-label">Debts to settle up</div>
    <div class="debt-list">${debtListHTML}</div>

    <div class="counted-on">
      <div class="label">Counted on</div>
      <div class="date">${escapeHTML(dateLabel)}</div>
    </div>

    <div class="cta-stack">
      <a class="cta-primary" href="${escapeAttr(appLink)}">Open in non-bank app</a>
      <a class="cta-secondary" href="${escapeAttr(appStoreURL)}">Don't have the app? Install non-bank</a>
    </div>

    <div class="footnote">non-bank · private split tracker</div>
  </div>

  <!-- Identity picker overlay. Only shown when 3+ participants
       and no identity stored. Tapping a participant remembers them
       in localStorage by friend ID, so a friend who's picked
       themselves once is auto-recognised on every future share. -->
  <div class="modal" id="identityPicker" hidden>
    <div class="modal-backdrop" data-modal-close></div>
    <div class="modal-sheet">
      <div class="modal-header">
        <h2>Who are you?</h2>
        <p>Pick yourself so the math shows from your point of view. We remember your choice on this device only.</p>
      </div>
      <div class="picker-list">
        ${identityPickerRowsHTML}
      </div>
      <button type="button" class="picker-skip" data-modal-close>I'm not in this split</button>
    </div>
  </div>

  <!-- Paid upfront overlay — slide-up sheet showing who paid what.
       Copy matches iOS PaidUpfrontView: bold total + currency,
       caption "X person/people paid upfront for the purchase." -->
  <div class="modal" id="paidUpfrontSheet" hidden>
    <div class="modal-backdrop" data-modal-close></div>
    <div class="modal-sheet">
      <div class="modal-header sheet-header-ios">
        <div class="sheet-amount">
          <span class="int">${escapeHTML(formatAmountInteger(payload.ta))}</span>
          <span class="dec">${escapeHTML(formatAmountDecimal(payload.ta))}</span>
          <span class="cur">${escapeHTML(payload.c)}</span>
        </div>
        <p class="sheet-caption">${payerCount} ${payerCount === 1 ? "person" : "people"} paid upfront for the purchase.</p>
      </div>
      <div class="modal-list">
        ${paidUpfrontRowsHTML || `<div class="empty-row">No one paid upfront</div>`}
      </div>
      <button type="button" class="modal-close" data-modal-close>Done</button>
    </div>
  </div>

  <!-- Shares overlay — slide-up sheet showing each share.
       Copy matches iOS ShareDistributionView: split-mode pill
       ("50/50" / "Evenly") + "between X person/people". -->
  <div class="modal" id="sharesSheet" hidden>
    <div class="modal-backdrop" data-modal-close></div>
    <div class="modal-sheet">
      <div class="modal-header sheet-header-ios">
        <div class="sheet-mode-row">
          <span class="sheet-mode-pill">${escapeHTML(splitModeLabel)}</span>
          <span class="sheet-mode-text">between ${sharerCount} ${sharerCount === 1 ? "person" : "people"}</span>
        </div>
        <p class="sheet-caption">Each person's share of the purchase.</p>
      </div>
      <div class="modal-list">
        ${sharesRowsHTML || `<div class="empty-row">No participants</div>`}
      </div>
      <button type="button" class="modal-close" data-modal-close>Done</button>
    </div>
  </div>

  ${PAGE_SCRIPTS}
</body>
</html>`;
}

// ─── Sub-renderers ───────────────────────────────────────────────────

function renderPerspectiveBlocks(
  people: Person[],
  currency: string,
): string {
  // Render one block per friend (excluding sharer). The visible one is
  // selected by `body[data-viewer-id]` matching `data-id` here.
  // Plus a fallback "no identity yet" block (data-id="") shown by
  // default for 3+-person splits before the user picks.
  const friends = people.filter((p) => !p.isSharer);

  const blocks = friends.map((p) => {
    const delta = p.paid - p.share;
    const epsilon = 0.005;
    let label: string;
    let amount: number;
    if (Math.abs(delta) <= epsilon) {
      label = "You're settled";
      amount = 0;
    } else if (delta > 0) {
      label = "You lent";
      amount = delta;
    } else {
      label = "You borrow";
      amount = -delta;
    }
    // No leading +/- on the amount — the iOS app's split-detail block
    // shows the absolute number with the verb ("You lent" / "You
    // borrow") carrying the direction. A sign there would read as a
    // double negative on a "You borrow" block.
    return `
      <div class="perspective-block" data-id="${escapeAttr(p.id)}">
        <div class="perspective-label">${escapeHTML(label)}<span class="who-am-i" data-action="open-picker"> · not you?</span></div>
        ${
          amount > 0
            ? `<div class="amount-row">
                <span class="amount-int">${escapeHTML(formatAmountInteger(amount))}</span>
                <span class="amount-dec">${escapeHTML(formatAmountDecimal(amount))}</span>
                <span class="amount-currency">${escapeHTML(currency)}</span>
              </div>`
            : `<div class="settled-row">No money owed in either direction.</div>`
        }
      </div>`;
  });

  // Default placeholder shown when no identity is selected yet.
  const noIdentityHTML = `
    <div class="perspective-block" data-id="">
      <div class="perspective-label">Tap to pick who you are<span class="who-am-i" data-action="open-picker"> · choose →</span></div>
      <div class="amount-row">
        <span class="amount-int">${escapeHTML(formatAmountInteger(people.length > 0 ? people[0].paid + people[0].share : 0))}</span>
        <span class="amount-currency">${escapeHTML(currency)}</span>
      </div>
    </div>`;

  return [noIdentityHTML, ...blocks].join("\n");
}

function renderPeopleAvatars(people: Person[]): string {
  const visible = people.slice(0, 4);
  const overflow = Math.max(0, people.length - visible.length);
  const visibleHTML = visible
    .map((p) => `<div class="a">${pixelCatSVG(p.id, 32)}</div>`)
    .join("");
  const overflowHTML = overflow > 0
    ? `<div class="a overflow"><span>+${overflow}</span></div>`
    : "";
  return `<div class="avatars">${visibleHTML}${overflowHTML}</div>`;
}

function debtRowHTML(transfer: SimplifiedTransfer, currency: string): string {
  return `
    <div class="debt-row">
      <div class="avatar">${pixelCatSVG(transfer.fromId, 32)}</div>
      <div class="debt-text"><b>${escapeHTML(transfer.fromName)}</b> lent <b>${escapeHTML(transfer.toName)}</b></div>
      <div class="debt-amount">
        <span>${escapeHTML(formatAmountInteger(transfer.amount))}${escapeHTML(formatAmountDecimal(transfer.amount))}</span>
        <span class="cur">${escapeHTML(currency)}</span>
      </div>
    </div>`;
}

function sheetParticipantRow(person: Person, value: number, currency: string): string {
  return `
    <div class="sheet-row">
      <div class="sheet-avatar">${pixelCatSVG(person.id, 36)}</div>
      <div class="sheet-name">${escapeHTML(person.name)}${person.isSharer ? "<span class='sharer-tag'>shared this</span>" : ""}</div>
      <div class="sheet-value">${escapeHTML(formatAmount(value, currency))}</div>
    </div>`;
}

function identityPickerRowHTML(person: Person): string {
  return `
    <button type="button" class="picker-row" data-pick-id="${escapeAttr(person.id)}">
      <div class="picker-avatar">${pixelCatSVG(person.id, 40)}</div>
      <div class="picker-name">${escapeHTML(person.name)}</div>
      <span class="picker-arrow" aria-hidden="true">→</span>
    </button>`;
}

function errorPage(message: string): string {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>non-bank · share link</title>
<style>
  body { font-family: -apple-system, sans-serif; background: #0a0807; color: #f4ede4; min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 20px; }
  .box { max-width: 360px; text-align: center; }
  h1 { font-size: 22px; margin-bottom: 12px; }
  p { color: #8a8076; font-size: 14px; line-height: 1.5; }
  @media (prefers-color-scheme: light) { body { background: #f7f3ee; color: #1c1816; } p { color: #6b5d4f; } }
</style></head>
<body><div class="box"><h1>Couldn't open this share link</h1><p>${escapeHTML(message)}</p></div></body></html>`;
}

// ─── Inline CSS ──────────────────────────────────────────────────────

const PAGE_STYLES = `
<style>
  /* Tokens — mirror iOS AppColors / colorContext(.split). */
  :root {
    color-scheme: dark light;
    --bg: #0a0807;
    --surface: #1a1614;
    --surface-elevated: #221c19;
    --text: #f4ede4;
    --text-secondary: #b8a695;
    --text-tertiary: #8a8076;
    --text-quaternary: #5c554d;
    --border: #2a2421;
    --split-accent: #c8afe1;
    --split-accent-bold: #946DEB;
    --split-people: #422980;
    --warm-cta: #c79566;
    --warm-cta-bold: #a06d3a;
    --danger: #c14a6e;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f7f3ee;
      --surface: #ffffff;
      --surface-elevated: #fbf6ef;
      --text: #1c1816;
      --text-secondary: #6b5d4f;
      --text-tertiary: #8a8076;
      --text-quaternary: #b8a695;
      --border: #efe7dc;
      --split-accent: #6E46B4;
      --split-accent-bold: #8C5DEB;
      --split-people: #4a2d8f;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
  html, body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    -webkit-font-smoothing: antialiased;
  }

  .banner {
    background: var(--surface-elevated);
    border-bottom: 1px solid var(--border);
    padding: 14px 20px;
    /* Column-flex stacks the sharer line on top, the viewer-tag pill
       below — earlier inline layout had the pill bumping into the
       text on narrow screens (the layout the user flagged). */
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: var(--text-secondary);
    text-align: center;
  }
  .banner b { color: var(--text); font-weight: 600; }

  .page {
    max-width: 480px;
    margin: 0 auto;
    padding: 32px 20px 32px;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
  }

  /* Header — emoji tile + title + category + recurring */
  .header {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-bottom: 28px;
  }
  .emoji-tile {
    width: 64px; height: 64px;
    border-radius: 16px;
    background: var(--surface-elevated);
    border: 1px solid var(--border);
    display: flex; align-items: center; justify-content: center;
    font-size: 36px;
    flex-shrink: 0;
  }
  .title-block { flex: 1; min-width: 0; }
  .header h1 {
    font-size: 22px;
    font-weight: 700;
    line-height: 1.2;
    margin-bottom: 4px;
    word-break: break-word;
  }
  .header .category {
    font-size: 14px;
    color: var(--text-secondary);
  }
  .header .recurring {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    margin-top: 6px;
    font-size: 12px;
    color: var(--split-accent);
    pointer-events: none;
    user-select: none;
  }

  /* Perspective block — "You lent X" or picker prompt */
  .perspective { margin-bottom: 24px; }
  .perspective-block { display: none; }
  /* When body has no viewer, show the "tap to pick" placeholder. */
  body[data-viewer-id=""] .perspective-block[data-id=""] { display: block; }
  /* When body has a viewer, show ONLY that participant's block. */
  body:not([data-viewer-id=""]) .perspective-block[data-id=""] { display: none; }
  body[data-viewer-id="__placeholder"] .perspective-block { display: none; }
  /* Generated dynamically per participant — JS sets selector below. */
  .perspective-label {
    font-size: 14px;
    color: var(--text-secondary);
    margin-bottom: 8px;
  }
  .perspective-label .who-am-i {
    color: var(--split-accent);
    cursor: pointer;
    user-select: none;
  }
  .perspective-label .who-am-i:active { opacity: 0.6; }
  /* Hide the "not you?" hint when only 2 people (auto-picked, no
     ambiguity). The body data-needs-picker flag drives this. */
  body[data-needs-picker="0"] .who-am-i { display: none; }
  .amount-row {
    display: flex;
    align-items: baseline;
    gap: 6px;
    flex-wrap: wrap;
  }
  .amount-sign { font-size: 26px; color: var(--text-secondary); }
  .amount-int {
    font-size: 32px;
    font-weight: 700;
    letter-spacing: -0.5px;
  }
  .amount-dec { font-size: 22px; font-weight: 500; color: var(--text-secondary); }
  .amount-currency { font-size: 17px; color: var(--text-secondary); }
  .settled-row { font-size: 15px; color: var(--text-secondary); }

  /* Two-tone split card */
  .split-card {
    border-radius: 18px;
    overflow: visible;
    margin-bottom: 12px;
  }
  .split-section {
    width: 100%;
    border: 0;
    color: white;
    text-align: center;
    cursor: pointer;
    font: inherit;
    padding: 22px 16px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    transition: transform 0.08s ease, filter 0.15s ease;
  }
  .split-section:active { transform: scale(0.99); filter: brightness(1.05); }
  .split-section .split-amount {
    display: flex;
    align-items: baseline;
    gap: 4px;
  }
  .split-section .split-amount .int { font-size: 32px; font-weight: 700; }
  .split-section .split-amount .dec { font-size: 20px; color: rgba(255,255,255,0.85); }
  .split-section .split-amount .cur { font-size: 13px; color: rgba(255,255,255,0.85); margin-left: 4px; }
  .split-section .split-label {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 13px;
    color: rgba(255,255,255,0.92);
  }
  .split-section.purchase {
    background: var(--split-accent-bold);
    border-radius: 18px 18px 0 0;
    /* Concave bottom — quad-Bezier mirroring iOS TopArchShape.
       Path is in objectBoundingBox units (0–1), so archDepth scales
       to ~8% of the section height — same proportional cut iOS gives
       at archDepth=8 on a ~100pt tall section. */
    clip-path: url(#topArch);
    padding-bottom: 24px;
  }
  .split-section.people {
    background: var(--split-people);
    border-radius: 0 0 18px 18px;
    /* Convex top — quad-Bezier mirroring iOS BottomArchShape. The
       hump fits into its own box (corners at y=0.08, peak at y=0).
       No negative margin on the section any more — the curved gap
       between the two halves is produced naturally by the matched
       arches reading the page background through. */
    clip-path: url(#bottomArch);
    padding-top: 24px;
  }
  .split-section .avatars {
    display: flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 4px;
  }
  .split-section .avatars .a {
    width: 32px; height: 32px;
    border-radius: 50%;
    overflow: hidden;
    border: 2px solid var(--split-people);
    box-shadow: 0 0 0 1px rgba(255,255,255,0.15);
    flex-shrink: 0;
  }
  .split-section .avatars .a + .a { margin-left: -10px; }
  .split-section .avatars .a svg { display: block; width: 100%; height: 100%; }
  .split-section .avatars .a.overflow {
    background: rgba(255,255,255,0.28);
    color: white;
    display: flex; align-items: center; justify-content: center;
    font-size: 11px; font-weight: 600;
    border: 2px solid var(--split-people);
  }

  /* Formula legend */
  .formula {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    font-size: 12px;
    color: var(--text-secondary);
    margin: 4px 4px 28px;
  }
  /* Each labelled term is its own inline-flex so the dot vertically
     centres against the cap height of the adjacent text. The earlier
     inline-block + vertical-align middle aligned to the letter
     midline (x-height), which on the secondary-grey text read as the
     dot floating above the text — what the user flagged. */
  .formula > span {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .formula .dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .formula .dot.purchase { background: var(--split-accent-bold); }
  .formula .dot.people { background: var(--split-people); }
  .formula .op { color: var(--text-tertiary); }

  /* Debts to settle up */
  .section-label {
    font-size: 13px;
    color: var(--text-secondary);
    margin-bottom: 10px;
  }
  .debt-list { margin-bottom: 24px; }
  .debt-row {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px 18px;
    background: var(--surface-elevated);
    border-radius: 14px;
  }
  .debt-row + .debt-row { margin-top: 8px; }
  .debt-row .avatar {
    width: 32px; height: 32px;
    border-radius: 50%;
    overflow: hidden;
    flex-shrink: 0;
  }
  .debt-row .avatar svg { display: block; width: 100%; height: 100%; }
  .debt-row .avatar.settled {
    background: var(--surface);
    color: var(--split-accent);
    display: flex; align-items: center; justify-content: center;
    font-weight: 600; font-size: 13px;
  }
  .debt-row .debt-text {
    flex: 1;
    font-size: 15px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .debt-row .debt-text b { color: var(--text); font-weight: 600; }
  .debt-row .debt-amount {
    display: flex; align-items: baseline; gap: 4px;
    font-size: 15px;
    font-weight: 600;
    white-space: nowrap;
  }
  .debt-row .debt-amount .cur {
    font-size: 12px;
    color: var(--text-secondary);
    font-weight: 400;
  }
  .debt-row.balanced { background: transparent; border: 1px dashed var(--border); }

  .counted-on { margin-bottom: 28px; }
  .counted-on .label { font-size: 13px; color: var(--text-secondary); margin-bottom: 4px; }
  .counted-on .date { font-size: 16px; color: var(--text); }

  .cta-stack {
    margin-top: auto;
    padding-top: 24px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .cta-primary {
    background: linear-gradient(135deg, var(--warm-cta), var(--warm-cta-bold));
    color: #1c1816;
    text-align: center;
    padding: 16px;
    border-radius: 14px;
    font-size: 16px;
    font-weight: 600;
    text-decoration: none;
    transition: transform 0.1s ease;
  }
  .cta-primary:active { transform: scale(0.98); }
  @media (prefers-color-scheme: light) { .cta-primary { color: #ffffff; } }
  .cta-secondary {
    background: transparent;
    color: var(--text-secondary);
    text-align: center;
    padding: 12px;
    font-size: 14px;
    text-decoration: none;
  }
  .cta-secondary:active { color: var(--text); }
  .footnote { text-align: center; font-size: 11px; color: var(--text-quaternary); padding-top: 20px; }

  /* ── Modal overlays (identity picker, paid-upfront, shares) ── */
  .modal {
    position: fixed; inset: 0;
    z-index: 100;
    display: flex;
    align-items: flex-end;
    justify-content: center;
  }
  .modal[hidden] { display: none; }
  .modal-backdrop {
    position: absolute; inset: 0;
    background: rgba(0,0,0,0.55);
    animation: backdropIn 0.2s ease;
  }
  .modal-sheet {
    position: relative;
    width: 100%;
    max-width: 480px;
    max-height: 85vh;
    background: var(--bg);
    border-radius: 24px 24px 0 0;
    padding: 24px 20px 32px;
    overflow-y: auto;
    animation: sheetIn 0.28s cubic-bezier(0.2, 0.8, 0.2, 1);
    box-shadow: 0 -8px 30px rgba(0,0,0,0.4);
  }
  @media (min-width: 640px) {
    .modal { align-items: center; }
    .modal-sheet { border-radius: 24px; max-height: 80vh; }
  }
  @keyframes backdropIn { from { opacity: 0; } to { opacity: 1; } }
  @keyframes sheetIn { from { transform: translateY(100%); } to { transform: translateY(0); } }

  .modal-header { margin-bottom: 18px; }
  .modal-header h2 { font-size: 20px; font-weight: 700; margin-bottom: 6px; }
  .modal-header p { font-size: 13px; color: var(--text-secondary); }
  /* iOS PaidUpfrontView / ShareDistributionView headers — bold total
     amount or split-mode pill, then a caption beneath. Mirrors the
     in-app push-detail header so the modal lands as the same screen. */
  .sheet-header-ios .sheet-amount {
    display: flex;
    align-items: baseline;
    gap: 4px;
    margin-bottom: 6px;
  }
  .sheet-header-ios .sheet-amount .int { font-size: 32px; font-weight: 700; }
  .sheet-header-ios .sheet-amount .dec { font-size: 22px; color: var(--text-secondary); }
  .sheet-header-ios .sheet-amount .cur { font-size: 17px; color: var(--text-secondary); margin-left: 4px; }
  .sheet-header-ios .sheet-caption { font-size: 13px; color: var(--text-secondary); }
  .sheet-header-ios .sheet-mode-row { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
  .sheet-header-ios .sheet-mode-pill {
    font-size: 12px;
    font-weight: 500;
    padding: 3px 10px;
    border-radius: 999px;
    background: var(--surface-elevated);
    color: var(--text);
  }
  .sheet-header-ios .sheet-mode-text { font-size: 18px; font-weight: 700; }

  /* Viewer identity indicator — tiny pill at the top showing whose
     perspective the page renders. Tap to reopen the picker. */
  .viewer-tag {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 999px;
    padding: 3px 12px 3px 4px;
    font-size: 12px;
    color: var(--text-secondary);
    cursor: pointer;
    font: inherit;
    text-decoration: none;
    /* Centered inside the column-flex banner — no align-self needed. */
  }
  .viewer-tag:active { background: var(--border); }
  .viewer-tag .vt-avatar {
    width: 22px; height: 22px;
    border-radius: 50%;
    overflow: hidden;
    flex-shrink: 0;
  }
  .viewer-tag .vt-avatar svg { display: block; width: 100%; height: 100%; }
  .viewer-tag .vt-name { color: var(--text); font-weight: 500; }
  /* Hide when no viewer chosen yet (data-viewer-id="" on body). */
  body[data-viewer-id=""] .viewer-tag { display: none; }
  /* JS will populate the avatar + name based on the viewer id. */

  .modal-list {
    background: var(--surface-elevated);
    border-radius: 14px;
    padding: 4px 0;
    margin-bottom: 18px;
  }
  .sheet-row {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 12px 16px;
  }
  .sheet-row + .sheet-row { border-top: 1px solid var(--border); }
  .sheet-avatar { width: 36px; height: 36px; border-radius: 50%; overflow: hidden; flex-shrink: 0; }
  .sheet-avatar svg { display: block; width: 100%; height: 100%; }
  .sheet-name {
    flex: 1;
    font-size: 15px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .sharer-tag {
    margin-left: 8px;
    color: var(--text-tertiary);
    font-size: 12px;
  }
  .sheet-value { font-size: 14px; color: var(--text-secondary); white-space: nowrap; }
  .empty-row { padding: 16px; color: var(--text-tertiary); text-align: center; }

  .modal-close {
    width: 100%;
    padding: 14px;
    background: var(--surface-elevated);
    color: var(--text);
    border: 0;
    border-radius: 14px;
    font: inherit;
    font-weight: 600;
    cursor: pointer;
  }
  .modal-close:active { background: var(--border); }

  /* Identity picker rows */
  .picker-list {
    background: var(--surface-elevated);
    border-radius: 14px;
    overflow: hidden;
    margin-bottom: 14px;
  }
  .picker-row {
    width: 100%;
    border: 0;
    background: transparent;
    color: var(--text);
    font: inherit;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px 16px;
    cursor: pointer;
    text-align: left;
  }
  .picker-row + .picker-row { border-top: 1px solid var(--border); }
  .picker-row:active { background: var(--border); }
  .picker-avatar { width: 40px; height: 40px; border-radius: 50%; overflow: hidden; flex-shrink: 0; }
  .picker-avatar svg { display: block; width: 100%; height: 100%; }
  .picker-name { flex: 1; font-size: 16px; }
  .picker-arrow { color: var(--text-tertiary); font-size: 18px; }
  .picker-skip {
    width: 100%;
    padding: 12px;
    background: transparent;
    color: var(--text-secondary);
    border: 0;
    font: inherit;
    cursor: pointer;
  }
  .picker-skip:active { color: var(--text); }
</style>`;

// ─── Inline JS ───────────────────────────────────────────────────────

const PAGE_SCRIPTS = `
<script>
(function() {
  // ── Identity picker: persist across transactions ──
  // localStorage key holds the participant ID the user has identified
  // as. On load, if any participant in this share matches the stored
  // ID, auto-select. Otherwise, for 3+-person splits, show the picker
  // overlay so the user picks once. The picker can be reopened via the
  // "not you?" link in the perspective block.
  var IDENTITY_KEY = "nb-identity";
  var body = document.body;
  var needsPicker = body.getAttribute("data-needs-picker") === "1";

  // Pre-rendered (id → {name, svg}) map embedded server-side so the
  // viewer-tag swap doesn't need to know how to draw a pixel cat.
  var viewerIndex = {};
  try {
    var raw = document.getElementById("viewerIndex");
    if (raw && raw.textContent) viewerIndex = JSON.parse(raw.textContent);
  } catch (e) {}

  function applyViewer(id) {
    body.setAttribute("data-viewer-id", id || "");
    // Apply per-block visibility via attribute selector. Generated as
    // CSS at runtime so we don't need to know participant IDs at
    // template time.
    var styleId = "viewer-style";
    var existing = document.getElementById(styleId);
    if (existing) existing.remove();
    if (!id) return;
    var style = document.createElement("style");
    style.id = styleId;
    style.textContent =
      'body[data-viewer-id="' + cssEscape(id) + '"] .perspective-block[data-id="' + cssEscape(id) + '"] { display: block; }' +
      'body[data-viewer-id="' + cssEscape(id) + '"] .perspective-block:not([data-id="' + cssEscape(id) + '"]) { display: none; }';
    document.head.appendChild(style);

    // Populate the viewer-tag indicator from the pre-built index.
    var info = viewerIndex[id];
    if (info) {
      var avatarHost = document.getElementById("viewerAvatar");
      var nameEl = document.getElementById("viewerName");
      if (avatarHost) avatarHost.innerHTML = info.svg;
      if (nameEl) nameEl.textContent = info.name;
    }
  }

  function cssEscape(s) {
    // Minimal CSS-attribute escape for double quotes / backslashes.
    return String(s).replace(/\\\\/g, "\\\\\\\\").replace(/"/g, '\\\\"');
  }

  function readStoredIdentity() {
    try { return localStorage.getItem(IDENTITY_KEY) || null; } catch (e) { return null; }
  }
  function writeStoredIdentity(id) {
    try { localStorage.setItem(IDENTITY_KEY, id); } catch (e) {}
  }

  // Auto-select: prefer body[data-viewer-id] if pre-set (2-person
  // case), else look up localStorage and match against participants.
  var preset = body.getAttribute("data-viewer-id");
  if (preset) {
    applyViewer(preset);
  } else {
    var stored = readStoredIdentity();
    var participantIds = Array.prototype.map.call(
      document.querySelectorAll(".perspective-block[data-id]"),
      function(el) { return el.getAttribute("data-id"); }
    );
    if (stored && participantIds.indexOf(stored) !== -1) {
      applyViewer(stored);
    } else if (needsPicker) {
      openModal("identityPicker");
    }
  }

  // ── Modal handling ──
  function openModal(id) {
    var m = document.getElementById(id);
    if (!m) return;
    m.removeAttribute("hidden");
    document.documentElement.style.overflow = "hidden";
  }
  function closeModal(m) {
    if (!m) return;
    m.setAttribute("hidden", "");
    document.documentElement.style.overflow = "";
  }
  // Close on backdrop / close-button taps.
  document.addEventListener("click", function(e) {
    var t = e.target;
    if (!(t instanceof Element)) return;
    if (t.matches("[data-modal-close]") || t.closest("[data-modal-close]")) {
      var modal = t.closest(".modal");
      if (modal) closeModal(modal);
      return;
    }
    var picked = t.closest("[data-pick-id]");
    if (picked) {
      var id = picked.getAttribute("data-pick-id");
      if (id) {
        writeStoredIdentity(id);
        applyViewer(id);
        closeModal(document.getElementById("identityPicker"));
      }
      return;
    }
    var pickerOpener = t.closest("[data-action='open-picker']");
    if (pickerOpener) {
      openModal("identityPicker");
      return;
    }
    var sheetOpener = t.closest(".split-section[data-target]");
    if (sheetOpener) {
      var target = sheetOpener.getAttribute("data-target");
      if (target) openModal(target);
      return;
    }
  });

  // Close modals on Escape — common keyboard affordance.
  document.addEventListener("keydown", function(e) {
    if (e.key === "Escape") {
      Array.prototype.forEach.call(document.querySelectorAll(".modal:not([hidden])"), closeModal);
    }
  });
})();
</script>`;

// ─── Helpers ──────────────────────────────────────────────────────────

function htmlResponse(html: string, status = 200): Response {
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-frame-options": "DENY",
      "referrer-policy": "no-referrer",
    },
  });
}

function base64urlDecodeToString(s: string): string {
  let normalized = s.replace(/-/g, "+").replace(/_/g, "/");
  const padding = normalized.length % 4;
  if (padding > 0) normalized += "=".repeat(4 - padding);
  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder("utf-8").decode(bytes);
}

function escapeHTML(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttr(s: string): string {
  return escapeHTML(s);
}

/// Pre-rendered avatar SVGs + names keyed by participant id. Embedded
/// in the page as a JSON blob so the viewer-tag indicator can swap
/// to the chosen identity without re-running the pixel-cat algo on
/// the client. Compact: only the friend list (not the sharer — they
/// can't be the viewer).
function buildViewerIndex(people: Person[]): Record<string, { name: string; svg: string }> {
  const index: Record<string, { name: string; svg: string }> = {};
  for (const p of people) {
    if (p.isSharer) continue; // Sharer can't be the viewer.
    index[p.id] = { name: p.name, svg: pixelCatSVG(p.id, 22) };
  }
  return index;
}

/// Like `escapeJSString` but for content inside a `<script>` tag
/// (`type="application/json"`). Only the closing-tag sequence
/// `</script` is dangerous in JSON literals — backslashes / quotes
/// are JSON-legal.
function escapeJSScript(s: string): string {
  return s.replace(/<\/script/gi, "<\\/script");
}

function escapeJSString(s: string): string {
  return s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, "\\\"")
    .replace(/'/g, "\\'")
    .replace(/`/g, "\\`")
    .replace(/<\/script/gi, "<\\/script");
}

function formatAmount(value: number, currency: string): string {
  return `${formatAmountInteger(value)}${formatAmountDecimal(value)} ${currency}`;
}

function formatAmountInteger(value: number): string {
  const abs = Math.abs(value);
  const intPart = Math.trunc(abs);
  return intPart.toLocaleString("en-US").replace(/,/g, " ");
}

function formatAmountDecimal(value: number): string {
  const abs = Math.abs(value);
  const cents = Math.round((abs - Math.trunc(abs)) * 100);
  if (cents === 0) return "";
  return `.${String(cents).padStart(2, "0")}`;
}

function formatDate(unixSeconds: number): string {
  const ms = Math.round(unixSeconds * 1000);
  const d = new Date(ms);
  if (isNaN(d.getTime())) return "";
  return d.toLocaleDateString("en-US", {
    weekday: "short",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}
