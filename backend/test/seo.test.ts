import { describe, expect, it } from "vitest";
import { handleLandingPage } from "../src/landing.ts";
import { handleSupportPage } from "../src/support.ts";
import { handlePrivacyPage } from "../src/privacy.ts";
import { GUIDES, handleGuidePage } from "../src/guides.ts";
import {
  handleRobots,
  handleSitemap,
  handleOgImage,
  handleIcon,
  seoHead,
  SITE_PAGES,
  SITE_URL,
  APP_STORE_ID,
  INDEXNOW_KEY,
  handleSiteFile,
} from "../src/seo.ts";

const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

describe("seoHead", () => {
  it("emits canonical, Open Graph, Twitter card, smart banner and JSON-LD", () => {
    const head = seoHead({ path: "/support", title: 'A "quoted" <title>', description: "desc & more" });
    expect(head).toContain(`<link rel="canonical" href="${SITE_URL}/support">`);
    expect(head).toContain(`<meta property="og:url" content="${SITE_URL}/support">`);
    expect(head).toContain(`<meta property="og:image" content="${SITE_URL}/og.png">`);
    expect(head).toContain(`<meta name="twitter:card" content="summary_large_image">`);
    expect(head).toContain(`<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}">`);
    // Attribute values are escaped, so a quote in the title cannot break out.
    expect(head).toContain(`<title>A &quot;quoted&quot; &lt;title&gt;</title>`);
    expect(head).toContain(`content="desc &amp; more"`);
    expect(head).not.toContain('content="desc & more"');
  });

  it("merges extra JSON-LD objects into one array and keeps it script-safe", () => {
    const head = seoHead({
      path: "/",
      title: "t",
      description: "d",
      jsonLd: [{ "@type": "FAQPage", name: "</script><b>" }],
    });
    const m = head.match(/<script type="application\/ld\+json">(.*?)<\/script>/s);
    expect(m).not.toBeNull();
    const parsed = JSON.parse(m![1]);
    expect(Array.isArray(parsed)).toBe(true);
    expect(parsed[0]["@type"]).toBe("SoftwareApplication");
    expect(parsed[1]["@type"]).toBe("FAQPage");
    // `<` is escaped inside the script payload — no premature </script>.
    expect(m![1]).not.toContain("</script>");
  });
});

describe("public pages", () => {
  it.each([
    ["/", handleLandingPage],
    ["/support", handleSupportPage],
    ["/privacy", handlePrivacyPage],
  ])("%s carries the shared head exactly once", async (path, handler) => {
    const res = handler();
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("text/html");
    const html = await res.text();
    expect(html.match(/<link rel="canonical"/g)?.length).toBe(1);
    expect(html).toContain(`<link rel="canonical" href="${SITE_URL}${path}">`);
    expect(html.match(/<title>/g)?.length).toBe(1);
    expect(html.match(/<meta charset=/gi)?.length).toBe(1);
    expect(html.match(/application\/ld\+json/g)?.length).toBe(1);
  });

  it("landing page has one h1, enough body text, and links to every sitemap page", async () => {
    const html = await handleLandingPage().text();
    expect(html.match(/<h1[ >]/g)?.length).toBe(1);
    const text = html
      .replace(/<script[\s\S]*?<\/script>/g, " ")
      .replace(/<style[\s\S]*?<\/style>/g, " ")
      .replace(/<[^>]+>/g, " ");
    expect(text.split(/\s+/).filter(Boolean).length).toBeGreaterThan(400);
    for (const p of SITE_PAGES) {
      if (p.path !== "/") expect(html).toContain(`href="${p.path}"`);
    }
    expect(html).toContain(`apps.apple.com/app/id${APP_STORE_ID}`);
  });
});

describe("robots + sitemap", () => {
  it("robots allows the site, hides the API and share links, and points at the sitemap", async () => {
    const res = handleRobots();
    expect(res.headers.get("Content-Type")).toContain("text/plain");
    const body = await res.text();
    expect(body).toContain("User-agent: *\nAllow: /");
    expect(body).toContain("Disallow: /v1/");
    expect(body).toContain("Disallow: /share");
    expect(body).toContain(`Sitemap: ${SITE_URL}/sitemap.xml`);
  });

  it("sitemap lists every public page with a valid lastmod", async () => {
    const res = handleSitemap();
    expect(res.headers.get("Content-Type")).toContain("application/xml");
    const body = await res.text();
    expect(body.startsWith('<?xml version="1.0" encoding="UTF-8"?>')).toBe(true);
    for (const p of SITE_PAGES) {
      expect(body).toContain(`<loc>${SITE_URL}${p.path}</loc>`);
      expect(p.lastmod).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    }
    expect(body.match(/<url>/g)?.length).toBe(SITE_PAGES.length);
  });
});

describe("images", () => {
  it.each([
    ["og.png", handleOgImage],
    ["icon.png", handleIcon],
  ])("%s is a real PNG", async (_name, handler) => {
    const res = handler();
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/png");
    const bytes = new Uint8Array(await res.arrayBuffer());
    expect(Array.from(bytes.slice(0, 8))).toEqual(PNG_MAGIC);
    expect(bytes.length).toBeGreaterThan(10_000);
  });
});

describe("ownership files", () => {
  it("serves the IndexNow key file and nothing else", async () => {
    expect(INDEXNOW_KEY).toMatch(/^[0-9a-f]{32}$/);
    const res = handleSiteFile(`/${INDEXNOW_KEY}.txt`);
    expect(res).not.toBeNull();
    expect(await res!.text()).toBe(INDEXNOW_KEY);
    expect(handleSiteFile("/other.txt")).toBeNull();
    expect(handleSiteFile("/google0000.html")).toBeNull();
  });

  it("serves Google's verification file with the exact body Google expects", async () => {
    const res = handleSiteFile("/googleb9b14a1f82881a17.html");
    expect(res).not.toBeNull();
    expect(await res!.text()).toBe("google-site-verification: googleb9b14a1f82881a17.html");
  });
});

describe("guides", () => {
  const visibleText = (html: string) =>
    html
      .replace(/<script[\s\S]*?<\/script>/g, " ")
      .replace(/<style[\s\S]*?<\/style>/g, " ")
      .replace(/<[^>]+>/g, " ");

  it.each(GUIDES.map((g) => [g.path, g] as const))("%s is a full page in its own language", async (path, g) => {
    const res = handleGuidePage(path)!;
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain(`<html lang="${g.lang}">`);
    expect(html.match(/<link rel="canonical"/g)?.length).toBe(1);
    expect(html).toContain(`<link rel="canonical" href="${SITE_URL}${path}">`);
    expect(html.match(/<h1[ >]/g)?.length).toBe(1);
    expect(html.match(/<title>/g)?.length).toBe(1);
    expect(html.match(/application\/ld\+json/g)?.length).toBe(1);
    expect(html).toContain(`<meta property="og:locale" content="${g.locale}">`);
    expect(html).toContain(`<meta property="og:type" content="article">`);
    // Every language version names every other one, English as x-default.
    for (const o of GUIDES) {
      expect(html).toContain(`<link rel="alternate" hreflang="${o.hreflang}" href="${SITE_URL}${o.path}">`);
      if (o !== g) expect(html).toContain(`href="${o.path}"`);
    }
    expect(html).toContain(`<link rel="alternate" hreflang="x-default" href="${SITE_URL}${GUIDES[0].path}">`);
    expect(html).toContain(`href="/"`);
    expect(html).toContain(`apps.apple.com/app/id${APP_STORE_ID}`);
    // A real article, not a stub.
    expect(visibleText(html).split(/\s+/).filter(Boolean).length).toBeGreaterThan(550);
    // The FAQ markup is the visible FAQ; the article says which language it is in.
    const ld = JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)![1]);
    const byType = (t: string) => ld.find((o: { "@type": string }) => o["@type"] === t);
    expect(byType("FAQPage").mainEntity.map((q: { name: string }) => q.name)).toEqual(g.faq.map((f) => f.q));
    expect(html.match(/<details>/g)?.length).toBe(g.faq.length);
    expect(byType("Article").inLanguage).toBe(g.lang);
    expect(byType("Article").headline).toBe(g.h1);
  });

  it("titles and descriptions fit in search results", () => {
    for (const g of GUIDES) {
      expect(g.title.length).toBeLessThanOrEqual(60);
      expect(g.description.length).toBeLessThanOrEqual(160);
    }
  });

  it("every guide is in the sitemap", () => {
    for (const g of GUIDES) expect(SITE_PAGES.some((p) => p.path === g.path)).toBe(true);
  });

  it("a trailing slash redirects to the guide; other paths aren't guides", () => {
    const res = handleGuidePage(GUIDES[1].path + "/")!;
    expect(res.status).toBe(301);
    expect(res.headers.get("Location")).toBe(SITE_URL + GUIDES[1].path);
    expect(handleGuidePage("/")).toBeNull();
    expect(handleGuidePage("/support")).toBeNull();
    expect(handleGuidePage("/ru/")).toBeNull();
  });
});
