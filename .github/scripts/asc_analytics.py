#!/usr/bin/env python3
"""App Store Connect acquisition numbers, printed to the job log.

Two sources, because Apple exposes them differently:
  * Sales Reports  — daily units (downloads / updates / IAP) per country.
    Available immediately for any past day.
  * Analytics Reports — impressions, product page views, conversion.
    Only produced once an "analytics report request" exists for the app;
    the first instances land ~24-48h after the request is created. This
    script creates the request if needed and prints whatever is ready.

Auth: ASC API key (ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY). Nothing is
written to the account except the one-time report request.
"""
import csv
import datetime as dt
import gzip
import io
import os
import sys
import time
from collections import defaultdict

import jwt  # PyJWT
import requests

BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "nikitaspiridonov.non-bank")
VENDOR = os.environ.get("ASC_VENDOR_NUMBER", "94362919")
DAYS = int(os.environ.get("DAYS", "30"))


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"].strip()
    issuer = os.environ["ASC_ISSUER_ID"].strip()
    pem = os.environ["ASC_PRIVATE_KEY"]
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        pem, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
    )


S = requests.Session()


def api(method: str, path: str, **kw) -> requests.Response:
    S.headers["Authorization"] = f"Bearer {token()}"
    url = path if path.startswith("http") else BASE + path
    r = S.request(method, url, timeout=60, **kw)
    return r


def get_json(path: str, **kw) -> dict:
    r = api("GET", path, **kw)
    if r.status_code != 200:
        raise RuntimeError(f"GET {path} -> {r.status_code}: {r.text[:600]}")
    return r.json()


# ---------- Sales reports (immediate) ----------

# Product type identifiers we care about (iOS): 1F/1T free app download,
# 7F/7T update, 3F re-download, IA1/IA9/IAY in-app purchases.
DOWNLOAD_TYPES = {"1", "1F", "1T", "1E", "1EP", "1EU"}
UPDATE_TYPES = {"7", "7F", "7T"}
REDOWNLOAD_TYPES = {"3", "3F", "3T"}
IAP_TYPES = {"IA1", "IA9", "IAY", "IAC", "FI1"}


def sales_day(day: dt.date):
    r = api("GET", "/salesReports", params={
        "filter[frequency]": "DAILY",
        "filter[reportDate]": day.isoformat(),
        "filter[reportSubType]": "SUMMARY",
        "filter[reportType]": "SALES",
        "filter[vendorNumber]": VENDOR,
        "filter[version]": "1_1",
    }, headers={"Accept": "application/a-gzip"})
    if r.status_code == 404:
        return None  # no report for that day (no activity)
    if r.status_code != 200:
        raise RuntimeError(f"salesReports {day} -> {r.status_code}: {r.text[:400]}")
    text = gzip.decompress(r.content).decode("utf-8", errors="replace")
    return list(csv.DictReader(io.StringIO(text), delimiter="\t"))


def report_sales():
    print(f"\n=== App Store units by day, last {DAYS} days (Sales Reports, vendor {VENDOR}) ===")
    today = dt.date.today()
    per_day = {}
    by_country = defaultdict(lambda: defaultdict(int))
    missing = 0
    for i in range(DAYS, 0, -1):
        day = today - dt.timedelta(days=i)
        try:
            rows = sales_day(day)
        except RuntimeError as e:
            print(f"{day}: {e}")
            continue
        if rows is None:
            missing += 1
            continue
        agg = defaultdict(int)
        for row in rows:
            if row.get("SKU") and BUNDLE_ID.split(".")[-1] not in (row.get("SKU", "") + row.get("Title", "")).lower():
                pass  # single-app vendor; keep everything
            units = int(float(row.get("Units", "0") or 0))
            ptype = row.get("Product Type Identifier", "")
            country = row.get("Country Code", "?")
            if ptype in DOWNLOAD_TYPES:
                agg["downloads"] += units; by_country[country]["downloads"] += units
            elif ptype in UPDATE_TYPES:
                agg["updates"] += units; by_country[country]["updates"] += units
            elif ptype in REDOWNLOAD_TYPES:
                agg["redownloads"] += units; by_country[country]["redownloads"] += units
            elif ptype in IAP_TYPES:
                agg["iap"] += units; by_country[country]["iap"] += units
            else:
                agg[f"other:{ptype}"] += units
        per_day[day] = agg
    print(f"{'date':<10} {'downloads':>9} {'updates':>8} {'redl':>5} {'iap':>4}  other")
    tot = defaultdict(int)
    for day, agg in sorted(per_day.items()):
        other = ", ".join(f"{k[6:]}={v}" for k, v in agg.items() if k.startswith("other:"))
        print(f"{day} {agg['downloads']:>9} {agg['updates']:>8} {agg['redownloads']:>5} {agg['iap']:>4}  {other}")
        for k, v in agg.items():
            tot[k] += v
    print(f"{'TOTAL':<10} {tot['downloads']:>9} {tot['updates']:>8} {tot['redownloads']:>5} {tot['iap']:>4}")
    print(f"(days with no report at all: {missing} of {DAYS})")
    if by_country:
        print("\nby country:")
        for c, agg in sorted(by_country.items(), key=lambda kv: -sum(kv[1].values())):
            print(f"  {c:<4} " + "  ".join(f"{k}={v}" for k, v in agg.items()))


# ---------- Analytics reports (impressions etc.) ----------

def find_app_id() -> str:
    data = get_json("/apps", params={"filter[bundleId]": BUNDLE_ID, "fields[apps]": "name,bundleId"})["data"]
    if not data:
        raise RuntimeError(f"no app with bundle id {BUNDLE_ID}")
    print(f"app: {data[0]['attributes']['name']} (id {data[0]['id']})")
    return data[0]["id"]


def ensure_report_request(app_id: str) -> str:
    existing = get_json(f"/apps/{app_id}/analyticsReportRequests", params={"filter[accessType]": "ONGOING"})["data"]
    if existing:
        rr = existing[0]
        print(f"analytics report request exists: {rr['id']} (stoppedDueToInactivity={rr['attributes'].get('stoppedDueToInactivity')})")
        return rr["id"]
    r = api("POST", "/analyticsReportRequests", json={"data": {
        "type": "analyticsReportRequests",
        "attributes": {"accessType": "ONGOING"},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})
    if r.status_code not in (200, 201):
        raise RuntimeError(f"create report request -> {r.status_code}: {r.text[:600]}")
    rr = r.json()["data"]
    print(f"analytics report request CREATED: {rr['id']} — Apple starts producing daily reports in ~24-48h; re-run then.")
    return rr["id"]


WANTED_REPORTS = {
    "App Store Discovery and Engagement",  # impressions, product page views, taps
    "App Downloads",                       # first-time downloads, redownloads
    "App Store Installation and Deletion", # installs, deletions
}


def report_analytics():
    print("\n=== App Store analytics (impressions / page views / downloads) ===")
    app_id = find_app_id()
    rr_id = ensure_report_request(app_id)
    reports = get_json(f"/analyticsReportRequests/{rr_id}/reports", params={"limit": 200})["data"]
    if not reports:
        print("no reports available yet for this request (expected right after creation)")
        return
    names = sorted({r["attributes"]["name"] for r in reports})
    print(f"{len(reports)} report types available; wanted: {sorted(WANTED_REPORTS)}")
    cutoff = dt.date.today() - dt.timedelta(days=DAYS)
    for rep in reports:
        name = rep["attributes"]["name"]
        if name not in WANTED_REPORTS:
            continue
        inst = get_json(f"/analyticsReports/{rep['id']}/instances", params={"filter[granularity]": "DAILY", "limit": 200})["data"]
        inst = [i for i in inst if i["attributes"].get("processingDate", "") >= cutoff.isoformat()]
        print(f"\n--- {name}: {len(inst)} daily instances in window ---")
        if not inst:
            continue
        totals = defaultdict(lambda: defaultdict(float))
        for i in sorted(inst, key=lambda x: x["attributes"]["processingDate"]):
            segs = get_json(f"/analyticsReportInstances/{i['id']}/segments")["data"]
            for s in segs:
                blob = requests.get(s["attributes"]["url"], timeout=120).content
                text = gzip.decompress(blob).decode("utf-8", errors="replace")
                for row in csv.DictReader(io.StringIO(text), delimiter="\t"):
                    date = row.get("Date") or i["attributes"]["processingDate"]
                    for k, v in row.items():
                        if k in ("Date", "App Name", "App Apple Identifier") or v in (None, ""):
                            continue
                        try:
                            totals[date][k] += float(v)
                        except ValueError:
                            totals[date][f"{k}={v}"] += 1  # dimension value: count rows
        # Print numeric columns only, most informative first.
        numeric_cols = sorted({k for d in totals.values() for k, v in d.items() if "=" not in k})
        print("date        " + "  ".join(f"{c[:22]:>22}" for c in numeric_cols))
        for date in sorted(totals):
            print(f"{date:<11} " + "  ".join(f"{int(totals[date].get(c, 0)):>22}" for c in numeric_cols))
    print("\nall report types:", ", ".join(names))


def main():
    for name, fn in (("sales", report_sales), ("analytics", report_analytics)):
        try:
            fn()
        except Exception as e:
            print(f"\n=== {name}: FAILED ===\n{e}")


if __name__ == "__main__":
    main()
