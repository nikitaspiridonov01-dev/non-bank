#!/usr/bin/env python3
"""The team's signing certificates, and clean-up of the ones CI leaves behind.

Each release run archives on a fresh GitHub-hosted Mac, where
`xcodebuild -allowProvisioningUpdates` creates an Apple Development
certificate for that machine. Its private key goes away with the machine,
so the certificate is dead weight, and they pile up until Apple's limit
stops the next archive ("Your account has reached the maximum number of
certificates": release run 12, 1.0.7 build 19).

MODE=list (default): print every certificate. Read-only.
MODE=revoke-ci: revoke the development certificates made with the API key
  ("Created via API"), i.e. CI's. Certificates made in Xcode with an Apple
  ID and every distribution certificate are left alone.
  SERIAL=<hex> narrows it to the development certificate with that serial
  (release.yml revoking the one its own runner made).
DRY_RUN=1 prints what would be revoked without revoking.
"""
import os
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com/v1"
MODE = os.environ.get("MODE", "list")
DRY = os.environ.get("DRY_RUN", "0") == "1"
SERIAL = os.environ.get("SERIAL", "").strip().upper().lstrip("0")
DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}
CI_MARK = "Created via API"


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 900,
                       "aud": "appstoreconnect-v1"}, os.environ["ASC_PRIVATE_KEY"], algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


def call(method, path, **kw):
    r = requests.request(method, BASE + path, headers={"Authorization": f"Bearer {token()}"}, timeout=60, **kw)
    if r.status_code >= 300:
        raise RuntimeError(f"{method} {path} -> {r.status_code}: {r.text[:700]}")
    return r.json() if r.text else {}


def attrs(cert):
    return cert["attributes"]


def serial(cert):
    return (attrs(cert).get("serialNumber") or "").upper().lstrip("0")


def is_development(cert):
    return attrs(cert).get("certificateType") in DEVELOPMENT_TYPES


def is_ci(cert):
    return is_development(cert) and CI_MARK in f"{attrs(cert).get('name') or ''} {attrs(cert).get('displayName') or ''}"


def describe(cert):
    a = attrs(cert)
    return (f"{a.get('certificateType') or '?':<20} {a.get('name') or '-':<52} "
            f"display={a.get('displayName') or '-'!r:<24} expires {str(a.get('expirationDate'))[:10]}  "
            f"serial {a.get('serialNumber')}  id {cert['id']}")


def main():
    certs = sorted(call("GET", "/certificates", params={"limit": 200})["data"],
                   key=lambda c: attrs(c).get("expirationDate") or "")
    print(f"{len(certs)} certificates ([CI] = development, made with the API key):")
    for c in certs:
        print(("  [CI] " if is_ci(c) else "       ") + describe(c))
    if MODE == "list":
        return
    if MODE != "revoke-ci":
        raise SystemExit(f"unknown MODE {MODE!r}")
    if SERIAL:
        doomed = [c for c in certs if is_development(c) and serial(c) == SERIAL]
    else:
        doomed = [c for c in certs if is_ci(c)]
    print(f"\n{'would revoke' if DRY else 'revoking'} {len(doomed)}:")
    for c in doomed:
        print("  " + describe(c))
        if not DRY:
            call("DELETE", f"/certificates/{c['id']}")


if __name__ == "__main__":
    main()
