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


def ensure_report_request(app_id: str, access_type: str = "ONGOING") -> str:
    """ONGOING = daily reports from the request date on; ONE_TIME_SNAPSHOT =
    a one-off dump of history, which is the only way to get a "before"
    baseline for dates earlier than the ONGOING request."""
    existing = get_json(f"/apps/{app_id}/analyticsReportRequests", params={"filter[accessType]": access_type})["data"]
    if existing:
        rr = existing[0]
        print(f"{access_type} report request exists: {rr['id']} (stoppedDueToInactivity={rr['attributes'].get('stoppedDueToInactivity')})")
        return rr["id"]
    r = api("POST", "/analyticsReportRequests", json={"data": {
        "type": "analyticsReportRequests",
        "attributes": {"accessType": access_type},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})
    if r.status_code not in (200, 201):
        raise RuntimeError(f"create {access_type} report request -> {r.status_code}: {r.text[:600]}")
    rr = r.json()["data"]
    print(f"{access_type} report request CREATED: {rr['id']} — Apple produces it within ~24-48h; re-run then.")
    return rr["id"]


WANTED_REPORTS = {
    "App Store Discovery and Engagement Standard",  # impressions, product page views, taps
    "App Downloads Standard",                       # first-time downloads, redownloads
    "App Store Installation and Deletion Standard", # installs, deletions
}


def report_analytics():
    print("\n=== App Store analytics (impressions / page views / downloads) ===")
    app_id = find_app_id()
    snapshot_id = ensure_report_request(app_id, "ONE_TIME_SNAPSHOT")
    rr_id = ensure_report_request(app_id, "ONGOING")
    reports = []
    for req_id, label in ((snapshot_id, "snapshot"), (rr_id, "ongoing")):
        for rep in get_json(f"/analyticsReportRequests/{req_id}/reports", params={"limit": 200})["data"]:
            rep["_source"] = label
            reports.append(rep)
    if not reports:
        print("no reports available yet for these requests (expected right after creation)")
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
        print(f"\n--- {name} [{rep['_source']}]: {len(inst)} daily instances in window ---")
        if not inst:
            continue
        # Metrics are the "Counts"-style columns; everything else is a dimension.
        # Break each day down by the most informative dimension (Event for the
        # discovery report, Download Type for downloads, ...), so impressions
        # and product page views are not lumped into one number.
        METRIC_COLS = ("Counts", "Unique Counts", "Units", "Installs", "Deletions", "Downloads")
        SKIP_COLS = ("Date", "App Name", "App Apple Identifier")
        BREAKDOWN_PREFS = ("Event", "Download Type", "Event Type", "Source Type")
        # A daily instance can carry rows for several dates (late/revised
        # data), so the same date shows up in more than one instance. Keep,
        # per date, only the rows from the newest instance that has it —
        # summing across instances double-counts.
        rows_by_date = {}  # date -> (processingDate, [rows])
        for i in sorted(inst, key=lambda x: x["attributes"]["processingDate"]):
            pdate = i["attributes"]["processingDate"]
            segs = get_json(f"/analyticsReportInstances/{i['id']}/segments")["data"]
            fresh = defaultdict(list)
            for s in segs:
                blob = requests.get(s["attributes"]["url"], timeout=120).content
                text = gzip.decompress(blob).decode("utf-8", errors="replace")
                for row in csv.DictReader(io.StringIO(text), delimiter="\t"):
                    row.setdefault("Date", pdate)
                    fresh[row["Date"]].append(row)
            for date, drows in fresh.items():
                if date not in rows_by_date or rows_by_date[date][0] <= pdate:
                    rows_by_date[date] = (pdate, drows)
        rows = [r for _, drows in rows_by_date.values() for r in drows]
        if not rows:
            print("(instances exist but contain no rows)")
            continue
        cols = list(rows[0].keys())
        metrics = [c for c in cols if c in METRIC_COLS]
        dims = [c for c in cols if c not in METRIC_COLS and c not in SKIP_COLS]
        key = next((d for d in BREAKDOWN_PREFS if d in dims), None)

        def num(v):
            try:
                return float(v)
            except (TypeError, ValueError):
                return 0.0

        # date -> breakdown value -> metric -> total
        totals = defaultdict(lambda: defaultdict(lambda: defaultdict(float)))
        for row in rows:
            bucket = row.get(key, "all") if key else "all"
            for m in metrics:
                totals[row["Date"]][bucket][m] += num(row.get(m))
        print(f"dimensions: {', '.join(dims)}   breakdown by: {key or '(none)'}")
        print(f"{'date':<11} {'':<28}" + "".join(f"{m:>14}" for m in metrics))
        for date in sorted(totals):
            for bucket in sorted(totals[date]):
                vals = totals[date][bucket]
                print(f"{date:<11} {bucket[:28]:<28}" + "".join(f"{int(vals.get(m, 0)):>14}" for m in metrics))
        # Secondary view: where the traffic comes from (Source Type / Territory), summed over the window.
        for extra in ("Source Type", "Territory", "Page Type"):
            if extra in dims and extra != key:
                agg = defaultdict(float)
                for row in rows:
                    agg[row.get(extra, "?")] += num(row.get(metrics[0])) if metrics else 0
                top = sorted(agg.items(), key=lambda kv: -kv[1])[:8]
                print(f"  by {extra}: " + ", ".join(f"{k}={int(v)}" for k, v in top))
    print("\nall report types:", ", ".join(names))


def main():
    for name, fn in (("sales", report_sales), ("analytics", report_analytics)):
        try:
            fn()
        except Exception as e:
            print(f"\n=== {name}: FAILED ===\n{e}")


if __name__ == "__main__":
    main()
