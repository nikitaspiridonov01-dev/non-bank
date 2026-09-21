#!/usr/bin/env python3
"""Pull a handful of read-only reports from the GA4 Data API and print them.

Auth: a service-account JSON in GA4_SA_KEY_JSON (Viewer on the property).
Property: GA4_PROPERTY_ID. Nothing is written anywhere; the key is never
printed. Custom event parameters (e.g. balance_state) are only queryable
once registered as event-scoped custom dimensions in GA4 Admin — the
friend_detail report says so instead of failing the whole run.
"""
import argparse
import json
import os
import sys

import requests
from google.auth.transport.requests import Request
from google.oauth2 import service_account

API = "https://analyticsdata.googleapis.com/v1beta/properties/{prop}:runReport"
SCOPES = ["https://www.googleapis.com/auth/analytics.readonly"]


def access_token() -> str:
    raw = os.environ.get("GA4_SA_KEY_JSON", "")
    if not raw.strip():
        sys.exit("GA4_SA_KEY_JSON is empty")
    info = json.loads(raw)
    creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPES)
    creds.refresh(Request())
    print(f"auth ok as {info.get('client_email', '<unknown>')}")
    return creds.token


def run_report(token: str, prop: str, body: dict) -> dict:
    r = requests.post(
        API.format(prop=prop),
        headers={"Authorization": f"Bearer {token}"},
        json=body,
        timeout=60,
    )
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:900]}")
    return r.json()


def print_table(resp: dict, title: str) -> None:
    dims = [h["name"] for h in resp.get("dimensionHeaders", [])]
    mets = [h["name"] for h in resp.get("metricHeaders", [])]
    rows = resp.get("rows", [])
    print(f"\n=== {title} ({len(rows)} rows, {resp.get('rowCount', 0)} total) ===")
    if not rows:
        print("(no data)")
        return
    data = [
        [d["value"] for d in row.get("dimensionValues", [])]
        + [m["value"] for m in row.get("metricValues", [])]
        for row in rows
    ]
    headers = dims + mets
    widths = [max(len(h), *(len(r[i]) for r in data)) for i, h in enumerate(headers)]
    fmt = "  ".join("{:<" + str(w) + "}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*["-" * w for w in widths]))
    for r in data:
        print(fmt.format(*r))


def date_range(days: int) -> list:
    return [{"startDate": f"{days}daysAgo", "endDate": "today"}]


def report_daily(tok, prop, days):
    body = {
        "dateRanges": date_range(days),
        "dimensions": [{"name": "date"}],
        "metrics": [{"name": "activeUsers"}, {"name": "sessions"}, {"name": "eventCount"}],
        "orderBys": [{"dimension": {"dimensionName": "date"}}],
        "limit": 400,
    }
    print_table(run_report(tok, prop, body), f"Daily activity, last {days} days")


def report_events(tok, prop, days):
    body = {
        "dateRanges": date_range(days),
        "dimensions": [{"name": "eventName"}],
        "metrics": [{"name": "eventCount"}, {"name": "totalUsers"}],
        "orderBys": [{"metric": {"metricName": "eventCount"}, "desc": True}],
        "limit": 40,
    }
    print_table(run_report(tok, prop, body), f"Top events, last {days} days")


def report_versions(tok, prop, days):
    body = {
        "dateRanges": date_range(days),
        "dimensions": [{"name": "appVersion"}],
        "metrics": [{"name": "activeUsers"}, {"name": "sessions"}, {"name": "eventCount"}],
        "orderBys": [{"metric": {"metricName": "activeUsers"}, "desc": True}],
        "limit": 20,
    }
    print_table(run_report(tok, prop, body), f"App versions, last {days} days")


def report_friend_detail(tok, prop, days):
    base = {
        "dateRanges": date_range(days),
        "dimensionFilter": {
            "filter": {
                "fieldName": "eventName",
                "stringFilter": {"value": "friend_detail_viewed"},
            }
        },
        "metrics": [{"name": "eventCount"}, {"name": "totalUsers"}],
        "limit": 100,
    }
    # First the plain split by app version — always available.
    body = dict(base, dimensions=[{"name": "appVersion"}],
                orderBys=[{"metric": {"metricName": "eventCount"}, "desc": True}])
    print_table(run_report(tok, prop, body), f"friend_detail_viewed by app version, last {days} days")
    # Then by balance_state, which needs a registered custom dimension.
    body = dict(base, dimensions=[{"name": "appVersion"}, {"name": "customEvent:balance_state"}],
                orderBys=[{"dimension": {"dimensionName": "appVersion"}}])
    try:
        print_table(run_report(tok, prop, body), f"friend_detail_viewed by version × balance_state, last {days} days")
    except RuntimeError as e:
        print(f"\n=== friend_detail_viewed × balance_state: not available ===\n{e}")
        print(
            "Hint: register the event parameter as a custom dimension first —\n"
            "  GA4 Admin → Data display → Custom definitions → Create custom dimension:\n"
            "  scope Event, dimension name balance_state, event parameter balance_state.\n"
            "It only fills for events collected after registration."
        )


def report_screens(tok, prop, days):
    body = {
        "dateRanges": date_range(days),
        "dimensions": [{"name": "unifiedScreenName"}],
        "metrics": [{"name": "screenPageViews"}, {"name": "totalUsers"}, {"name": "userEngagementDuration"}],
        "orderBys": [{"metric": {"metricName": "screenPageViews"}, "desc": True}],
        "limit": 30,
    }
    print_table(run_report(tok, prop, body), f"Screens, last {days} days (engagement in seconds)")


def report_audience(tok, prop, days):
    body = {
        "dateRanges": date_range(days),
        "dimensions": [{"name": "newVsReturning"}],
        "metrics": [{"name": "activeUsers"}, {"name": "sessions"}, {"name": "averageSessionDuration"},
                    {"name": "sessionsPerUser"}],
        "limit": 10,
    }
    print_table(run_report(tok, prop, body), f"New vs returning, last {days} days")
    body = {
        "dateRanges": date_range(days),
        "dimensions": [{"name": "country"}],
        "metrics": [{"name": "activeUsers"}, {"name": "newUsers"}, {"name": "sessions"}],
        "orderBys": [{"metric": {"metricName": "activeUsers"}, "desc": True}],
        "limit": 15,
    }
    print_table(run_report(tok, prop, body), f"Countries, last {days} days")


def report_retention(tok, prop, days):
    # Weekly acquisition cohorts, users still active on day 1 / 7 / 14 / 28.
    weeks = max(1, min(6, days // 7))
    cohorts = []
    for i in range(weeks):
        cohorts.append({
            "name": f"w-{i}",
            "dimension": "firstSessionDate",
            "dateRange": {"startDate": f"{(i + 1) * 7}daysAgo", "endDate": f"{i * 7 + 1}daysAgo"},
        })
    body = {
        "dimensions": [{"name": "cohort"}, {"name": "cohortNthDay"}],
        "metrics": [{"name": "cohortActiveUsers"}],
        "cohortSpec": {
            "cohorts": cohorts,
            "cohortsRange": {"granularity": "DAILY", "startOffset": 0, "endOffset": 28},
        },
        "orderBys": [{"dimension": {"dimensionName": "cohort"}}, {"dimension": {"dimensionName": "cohortNthDay"}}],
        "limit": 1000,
    }
    resp = run_report(tok, prop, body)
    # Pivot: one line per cohort, retained users on the interesting days.
    days_of_interest = ["0000", "0001", "0003", "0007", "0014", "0028"]
    table = {}
    for row in resp.get("rows", []):
        c, d = (v["value"] for v in row["dimensionValues"])
        table.setdefault(c, {})[d] = row["metricValues"][0]["value"]
    print(f"\n=== Retention by weekly cohort (users active on day N), last {weeks} weeks ===")
    print("cohort  window                  " + "  ".join(f"d{int(d):>2}" for d in days_of_interest))
    for c in cohorts:
        r = table.get(c["name"], {})
        rng = f"{c['dateRange']['startDate']:>10}..{c['dateRange']['endDate']:<10}"
        print(f"{c['name']:<7} {rng}  " + "  ".join(f"{r.get(d, '-'):>3}" for d in days_of_interest))


REPORTS = {
    "daily": report_daily,
    "screens": report_screens,
    "audience": report_audience,
    "retention": report_retention,
    "events": report_events,
    "versions": report_versions,
    "friend_detail": report_friend_detail,
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--report", default="all", help="all | " + " | ".join(REPORTS))
    args = ap.parse_args()

    prop = os.environ.get("GA4_PROPERTY_ID", "").strip()
    if not prop:
        sys.exit("GA4_PROPERTY_ID is empty")
    print(f"property {prop}, window {args.days} days")

    tok = access_token()
    names = list(REPORTS) if args.report == "all" else [args.report]
    failures = 0
    for name in names:
        try:
            REPORTS[name](tok, prop, args.days)
        except Exception as e:  # keep going so one bad report doesn't hide the rest
            failures += 1
            print(f"\n=== {name}: FAILED ===\n{e}")
    if failures:
        sys.exit(f"{failures} report(s) failed")


if __name__ == "__main__":
    main()
