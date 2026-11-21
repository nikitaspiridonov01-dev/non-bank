#!/usr/bin/env python3
"""Bing Webmaster Tools for https://non-bank.app/.

Uses the key from Bing Webmaster Tools (Settings → API access), stored as the
BING_WEBMASTER_API_KEY secret. Run through ga4-report.yml:

  report=bing_status (read-only): the site's verification state, its
      sitemaps, crawl/index info for every URL in the live sitemap, daily
      crawl stats, and search traffic: clicks and impressions by day, top
      queries and pages. Bing's index also feeds DuckDuckGo and ChatGPT search.
  report=bing_submit: asks Bing to crawl the guides and the home page now
      (SubmitUrlBatch, within the site's daily URL quota). The sitemap and
      IndexNow only tell Bing the pages exist, and a young site can wait weeks
      for the crawl.
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sys

import requests

API = "https://ssl.bing.com/webmaster/api.svc/json/"
SITE = "https://non-bank.app/"
GUIDES_TS = pathlib.Path(__file__).resolve().parents[2] / "backend" / "src" / "guides.ts"


def api_key():
    key = os.environ.get("BING_WEBMASTER_API_KEY", "").strip()
    if not key:
        sys.exit("BING_WEBMASTER_API_KEY secret is missing")
    return key


def send(method, params=None, body=None):
    """One API request (a POST when there's a body): the response if Bing
    accepted it, else None.

    The key travels in the query string, so a failure prints the method and
    what the API said, never the URL or the exception text (which quotes it).
    """
    query = {"apikey": api_key(), **(params or {})}
    try:
        if body is None:
            r = requests.get(API + method, params=query, timeout=60)
        else:
            r = requests.post(API + method, params=query, data=json.dumps(body),
                              headers={"Content-Type": "application/json; charset=utf-8"},
                              timeout=60)
    except requests.RequestException as e:
        print(f"{method}: {type(e).__name__}")
        return None
    if not r.ok:
        print(f"{method}: HTTP {r.status_code} {r.text[:300]}")
        return None
    return r


def call(method, **params):
    r = send(method, params)
    return r.json().get("d") if r is not None else None


def stamp(value):
    """Milliseconds since the epoch in Bing's /Date(1731542400000-0800)/, or None."""
    m = re.search(r"/Date\((-?\d+)", str(value or ""))
    return int(m.group(1)) if m and int(m.group(1)) > 0 else None


def day(value):
    ms = stamp(value)
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).date().isoformat() if ms else "-"


def by_date(rows):
    return sorted(rows or [], key=lambda r: stamp(r.get("Date")) or 0)


def check_site():
    sites = call("GetUserSites")
    if sites is None:
        sys.exit("Bing Webmaster API unavailable")
    for s in sites:
        print(f"site {s.get('Url')}: verified={s.get('IsVerified')}")
    if not any((s.get("Url") or "").rstrip("/") == SITE.rstrip("/") for s in sites):
        sys.exit(f"{SITE} is not in this Bing Webmaster Tools account")


def status():
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


def quota():
    """The site's URL submission quota, (daily, monthly); None where unknown."""
    q = call("GetUrlSubmissionQuota", siteUrl=SITE) or {}
    return q.get("DailyQuota"), q.get("MonthlyQuota")


def submit():
    # The guides first (their paths come from their source, guides.ts), then
    # the home page that links to them: a small quota keeps the guides.
    paths = re.findall(r'^\s*path: "(/[^"]*)"', GUIDES_TS.read_text(), re.M)
    urls = [SITE.rstrip("/") + p for p in paths] + [SITE]

    daily, monthly = quota()
    print(f"quota before: daily={daily} monthly={monthly}")
    if isinstance(daily, int) and daily < len(urls):
        if daily <= 0:
            sys.exit("no URL submissions left today; try again tomorrow")
        print(f"only {daily} submissions left today: sending the first {daily}")
        urls = urls[:daily]

    if send("SubmitUrlBatch", body={"siteUrl": SITE, "urlList": urls}) is None:
        sys.exit("SubmitUrlBatch failed")
    print(f"submitted {len(urls)} URLs for crawling:")
    for url in urls:
        print(f"  {url}")
    daily, monthly = quota()
    print(f"quota after: daily={daily} monthly={monthly}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["status", "submit"], default="status")
    mode = parser.parse_args().mode
    check_site()
    {"status": status, "submit": submit}[mode]()


if __name__ == "__main__":
    main()
