#!/usr/bin/env python3
"""Print the live App Store product page metadata (read-only).

Name / subtitle / categories from appInfos, and description / keywords /
promotional text / what's new from the live App Store version, per locale.
Auth: the same ASC API key as release.yml.
"""
import os
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "nikitaspiridonov.non-bank")


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"], algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"},
    )


def get(path, **params):
    r = requests.get(BASE + path, headers={"Authorization": f"Bearer {token()}"}, params=params, timeout=60)
    if r.status_code != 200:
        raise RuntimeError(f"GET {path} -> {r.status_code}: {r.text[:500]}")
    return r.json()


def show(label, value):
    value = (value or "").strip()
    print(f"\n[{label}]  ({len(value)} chars)")
    print(value if value else "<empty>")


def main():
    app = get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]
    app_id = app["id"]
    print(f"app {app['attributes']['name']} ({app_id})  bundle {BUNDLE_ID}")
    print(f"primary locale: {app['attributes'].get('primaryLocale')}")

    # App-level info: name, subtitle, categories (appInfos, the live one).
    infos = get(f"/apps/{app_id}/appInfos", include="primaryCategory,secondaryCategory")["data"]
    live = next((i for i in infos if i["attributes"].get("appStoreState") in ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")), infos[0])
    rel = live.get("relationships", {})
    cats = {k: (rel.get(k, {}).get("data") or {}).get("id") for k in ("primaryCategory", "secondaryCategory")}
    print(f"appInfo state: {live['attributes'].get('appStoreState')}  categories: {cats}")
    print(f"age rating: {live['attributes'].get('appStoreAgeRating')}")
    for loc in get(f"/appInfos/{live['id']}/appInfoLocalizations")["data"]:
        a = loc["attributes"]
        print(f"\n===== appInfo localization {a['locale']} =====")
        show("name (30 max)", a.get("name"))
        show("subtitle (30 max)", a.get("subtitle"))
        show("privacy policy url", a.get("privacyPolicyUrl"))

    # Version-level: description, keywords, promo, what's new (live version).
    versions = get(f"/apps/{app_id}/appStoreVersions", **{"filter[platform]": "IOS", "limit": 5})["data"]
    for v in versions:
        a = v["attributes"]
        print(f"\n##### App Store version {a['versionString']}  state={a.get('appStoreState') or a.get('appVersionState')}  released={a.get('createdDate','')[:10]} #####")
        for loc in get(f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]:
            la = loc["attributes"]
            print(f"\n----- {la['locale']} -----")
            show("keywords (100 max, comma-separated)", la.get("keywords"))
            show("promotional text (170 max)", la.get("promotionalText"))
            show("description (4000 max)", la.get("description"))
            show("what's new", la.get("whatsNew"))
            show("marketing url", la.get("marketingUrl"))
            show("support url", la.get("supportUrl"))
        break  # newest version only


if __name__ == "__main__":
    main()
