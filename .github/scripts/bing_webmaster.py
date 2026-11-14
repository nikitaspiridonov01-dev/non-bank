#!/usr/bin/env python3
"""Bing Webmaster Tools report for https://non-bank.app/ (read-only).

Uses the key from Bing Webmaster Tools (Settings → API access), stored as the
BING_WEBMASTER_API_KEY secret. Prints the site's verification state, its
sitemaps, crawl/index info for every URL in the live sitemap, daily crawl
stats, and search traffic: clicks and impressions by day, top queries and
pages. Bing's index also feeds DuckDuckGo and ChatGPT search.

Run through ga4-report.yml with report=bing_status.
"""
import datetime as dt
import os
import re
import sys

import requests

API = "https://ssl.bing.com/webmaster/api.svc/json/"
SITE = "https://non-bank.app/"


def call(method, **params):
    key = os.environ.get("BING_WEBMASTER_API_KEY", "").strip()
    if not key:
        sys.exit("BING_WEBMASTER_API_KEY secret is missing")
    r = requests.get(API + method, params={"apikey": key, **params}, timeout=60)
    if not r.ok:
        # The key travels in the query string: print the method, never the URL.
        print(f"{method}: HTTP {r.status_code} {r.text[:300]}")
        return None
    return r.json().get("d")


def stamp(value):
    """Milliseconds since the epoch in Bing's /Date(1731542400000-0800)/, or None."""
    m = re.search(r"/Date\((-?\d+)", str(value or ""))
    return int(m.group(1)) if m and int(m.group(1)) > 0 else None


def day(value):
    ms = stamp(value)
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).date().isoformat() if ms else "-"


def by_date(rows):
    return sorted(rows or [], key=lambda r: stamp(r.get("Date")) or 0)


def main():
    sites = call("GetUserSites") or []
    for s in sites:
        print(f"site {s.get('Url')}: verified={s.get('IsVerified')}")
    if not any((s.get("Url") or "").rstrip("/") == SITE.rstrip("/") for s in sites):
        sys.exit(f"{SITE} is not in this Bing Webmaster Tools account")

    for f in call("GetFeeds", siteUrl=SITE) or []:
        print(f"sitemap {f.get('Url')}: status={f.get('Status')} urls={f.get('UrlCount')} "
              f"submitted={day(f.get('Submitted'))} lastCrawled={day(f.get('LastCrawled'))}")

    # Every URL the live sitemap lists, as Bing knows it.
    sitemap = requests.get(SITE + "sitemap.xml", timeout=30).text
    for url in re.findall(r"<loc>([^<]+)</loc>", sitemap):
        info = call("GetUrlInfo", siteUrl=SITE, url=url)
        if info is not None:
            print(f"url {url}: http={info.get('HttpStatus')} discovered={day(info.get('DiscoveryDate'))} "
                  f"lastCrawled={day(info.get('LastCrawledDate'))}")

    crawl = by_date(call("GetCrawlStats", siteUrl=SITE))
    print(f"crawl stats: {len(crawl)} days")
    for c in crawl[-14:]:
        print(f"  {day(c.get('Date'))} crawled={c.get('CrawledPages')} inIndex={c.get('InIndex')} "
              f"2xx={c.get('Code2xx')} 4xx={c.get('Code4xx')} 5xx={c.get('Code5xx')} "
              f"errors={c.get('CrawlErrors')} robotsBlocked={c.get('BlockedByRobotsTxt')}")

    traffic = by_date(call("GetRankAndTrafficStats", siteUrl=SITE))
    print(f"search traffic: {len(traffic)} days, impressions={sum(t.get('Impressions') or 0 for t in traffic)} "
          f"clicks={sum(t.get('Clicks') or 0 for t in traffic)}")
    for t in traffic:
        if t.get("Impressions") or t.get("Clicks"):
            print(f"  {day(t.get('Date'))} impressions={t.get('Impressions')} clicks={t.get('Clicks')}")

    for method, label in (("GetQueryStats", "queries"), ("GetPageStats", "pages")):
        rows = sorted(call(method, siteUrl=SITE) or [], key=lambda q: -(q.get("Impressions") or 0))
        print(f"top {label}: {len(rows)}")
        for q in rows[:20]:
            print(f"  {q.get('Query')!s:<55} impressions={q.get('Impressions')} clicks={q.get('Clicks')} "
                  f"avgPosition={q.get('AvgImpressionPosition')}")


if __name__ == "__main__":
    main()
