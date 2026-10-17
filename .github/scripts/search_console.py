#!/usr/bin/env python3
"""Google Search Console setup for https://non-bank.app/ through the APIs,
using the same service account as the GA4 reports (GA4_SA_KEY_JSON).

Modes (MODE env or --mode):
  probe   — check that the Site Verification and Search Console APIs are
            enabled for the service account's project; prints what to enable.
  token   — ask Google for an HTML-file verification token for the URL-prefix
            property https://non-bank.app/ and print the file name + content.
            The file is public by design (Google fetches it from the site).
  verify  — ask Google to verify ownership (the Worker must already serve the
            file from `token`).
  submit  — add the property to Search Console and submit the sitemap.
  status  — list the service account's properties, sitemaps and their state.
  owner   — add OWNER_EMAIL as a verified owner, so the property shows up in
            that person's own Search Console.

Request indexing ("Запросить индексирование") has no public API for ordinary
pages; the sitemap submission is the supported equivalent.
"""
import argparse
import json
import os
import sys

import requests
from google.auth.transport.requests import Request
from google.oauth2 import service_account

SITE = "https://non-bank.app/"
SITEMAP = "https://non-bank.app/sitemap.xml"
SCOPES = [
    "https://www.googleapis.com/auth/siteverification",
    "https://www.googleapis.com/auth/webmasters",
]
SV = "https://www.googleapis.com/siteVerification/v1"
WM = "https://www.googleapis.com/webmasters/v3"


def session():
    raw = os.environ.get("GA4_SA_KEY_JSON", "")
    if not raw.strip():
        sys.exit("GA4_SA_KEY_JSON secret is missing")
    info = json.loads(raw)
    creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPES)
    creds.refresh(Request())
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {creds.token}"
    print(f"auth ok as {info.get('client_email')} (project {info.get('project_id')})")
    return s, info


def show(label, r):
    try:
        body = r.json()
    except ValueError:
        body = r.text[:400]
    print(f"{label}: HTTP {r.status_code} {json.dumps(body, ensure_ascii=False)[:900]}")
    return r


def enc(url):
    return requests.utils.quote(url, safe="")


def probe(s, info):
    proj = info.get("project_id")
    ok = True
    r = show("site verification API", s.get(f"{SV}/webResource"))
    if r.status_code == 403 and ("has not been used" in r.text or "disabled" in r.text):
        ok = False
        print(f"  → enable: https://console.cloud.google.com/apis/library/siteverification.googleapis.com?project={proj}")
    r = show("search console API", s.get(f"{WM}/sites"))
    if r.status_code == 403 and ("has not been used" in r.text or "disabled" in r.text):
        ok = False
        print(f"  → enable: https://console.cloud.google.com/apis/library/searchconsole.googleapis.com?project={proj}")
    print("APIs ready" if ok else "APIs missing — enable the links above, then re-run")


def token(s):
    r = show("getToken", s.post(f"{SV}/token", json={
        "site": {"type": "SITE", "identifier": SITE},
        "verificationMethod": "FILE",
    }))
    if r.ok:
        name = r.json()["token"]
        print(f"VERIFICATION_FILE={name}")
        print(f"VERIFICATION_CONTENT=google-site-verification: {name}")


def verify(s):
    r = show("verify", s.post(f"{SV}/webResource?verificationMethod=FILE", json={
        "site": {"type": "SITE", "identifier": SITE},
    }))
    if r.ok:
        print(f"verified; owners: {r.json().get('owners')}")


def submit(s):
    show("sites.add", s.put(f"{WM}/sites/{enc(SITE)}"))
    show("sitemaps.submit", s.put(f"{WM}/sites/{enc(SITE)}/sitemaps/{enc(SITEMAP)}"))


def status(s):
    show("sites.list", s.get(f"{WM}/sites"))
    show("sitemaps.list", s.get(f"{WM}/sites/{enc(SITE)}/sitemaps"))
    show("webResource.list", s.get(f"{SV}/webResource"))


def owner(s):
    email = os.environ.get("OWNER_EMAIL", "").strip()
    if not email:
        sys.exit("OWNER_EMAIL is empty")
    rid = enc(SITE)
    r = show("webResource.get", s.get(f"{SV}/webResource/{rid}"))
    if not r.ok:
        return
    res = r.json()
    owners = res.get("owners", [])
    if email in owners:
        print(f"{email} is already an owner")
        return
    res["owners"] = owners + [email]
    show("webResource.update", s.put(f"{SV}/webResource/{rid}", json=res))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default=os.environ.get("MODE", "probe"))
    mode = ap.parse_args().mode
    s, info = session()
    {"probe": lambda: probe(s, info), "token": lambda: token(s), "verify": lambda: verify(s),
     "submit": lambda: submit(s), "status": lambda: status(s), "owner": lambda: owner(s)}[mode]()


if __name__ == "__main__":
    main()
