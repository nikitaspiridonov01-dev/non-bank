#!/usr/bin/env python3
"""Push the site's URLs to IndexNow (Bing, Yandex, Seznam, Naver, Yep).

The key lives in backend/src/seo.ts (INDEXNOW_KEY) and is served by the Worker
at https://non-bank.app/<key>.txt — search engines fetch it to confirm the
submission. Run after a deploy that changes public pages:

    python3 .github/scripts/indexnow.py
"""
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
SEO_TS = ROOT / "backend" / "src" / "seo.ts"
HOST = "non-bank.app"


def main() -> int:
    src = SEO_TS.read_text()
    key = re.search(r'INDEXNOW_KEY = "([0-9a-f]{32})"', src).group(1)
    paths = re.findall(r'\{ path: "(/[^"]*)", lastmod', src)
    urls = [f"https://{HOST}{p}" for p in paths]
    body = json.dumps({
        "host": HOST,
        "key": key,
        "keyLocation": f"https://{HOST}/{key}.txt",
        "urlList": urls,
    }).encode()
    req = urllib.request.Request(
        "https://api.indexnow.org/indexnow", data=body, method="POST",
        headers={"Content-Type": "application/json; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f"IndexNow: HTTP {r.status} for {len(urls)} URLs: {', '.join(urls)}")
            return 0
    except urllib.error.HTTPError as e:
        # 200/202 = accepted; 403 = key file not reachable; 422 = URLs not on host.
        print(f"IndexNow: HTTP {e.code} {e.read()[:300]!r}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
