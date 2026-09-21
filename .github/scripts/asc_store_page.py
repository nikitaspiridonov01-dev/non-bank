#!/usr/bin/env python3
"""Apply the App Store product-page refresh for the next version (ASC API).

MODE=metadata (default):
  * ensure App Store version TARGET_VERSION exists (create if missing)
  * promotional text on the LIVE version (takes effect without review)
  * name / subtitle per locale (appInfoLocalizations of the editable appInfo)
  * keywords / promo / description / what's new per locale
  * secondary category
MODE=attach:
  * attach the processed build whose version == TARGET_VERSION
DRY_RUN=1 prints every change without sending anything.
Nothing here submits for review — that stays a manual click in ASC.
"""
import json
import os
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "nikitaspiridonov.non-bank")
TARGET = os.environ.get("TARGET_VERSION", "1.0.2")
MODE = os.environ.get("MODE", "metadata")
DRY = os.environ.get("DRY_RUN", "0") == "1"
SECONDARY_CATEGORY = os.environ.get("SECONDARY_CATEGORY", "UTILITIES")

PRIVACY_URL = "https://non-bank.app/privacy"
MARKETING_URL = "https://non-bank.app"
SUPPORT_URL = "https://non-bank.app/support"

PROMO_EN = ("Private expense tracker & bill splitter. No bank login, no account, no ads — "
            "everything stays on your iPhone. Scan a receipt and split it item by item.")

DESC_EN = """Non Bank is a private expense tracker and bill splitter. No bank login, no account, no ads: your transactions, friends and receipts live on your iPhone and sync only through your own iCloud. We never see them.

SPLIT BILLS THE EASY WAY
• Split any expense evenly, by exact amounts, or item by item
• Scan a receipt and split it line by line
• Keep a running balance of who owes whom, and settle up in one tap
• Share a split with a friend — their copy updates automatically, encrypted end to end

TRACK YOUR MONEY
• Add expenses and income in seconds
• Organize with custom categories and emoji
• See where your money goes with clear, visual insights
• Recurring transactions and reminders so nothing slips
• Multiple currencies, converted at the day's rate

PRIVATE BY DESIGN
• Nothing leaves your device except to your own iCloud
• No sign-up, no email, no tracking of your spending
• Export everything as CSV or JSON whenever you want

Non Bank is for people who want to understand their money and settle up with friends, without giving up their privacy to do it.

Got an idea, or something you'd love Non Bank to do? Write to nonbankapp@gmail.com — every suggestion shapes what comes next."""

WHATS_NEW_EN = ("• Refreshed App Store page\n"
                "• Non Bank can now ask for a rating after a split — once, and only if you're enjoying it\n"
                "• Friend balances reflect only the money that moved between you and that friend")

LOCALES = {
    "en-US": {
        "name": "Non Bank: Expense & Bill Split",
        "subtitle": "Split bills, scan receipts",
        "keywords": "budget,spending,shared,expenses,group,trip,roommates,friends,settle,debt,cash,iou,tracker,private",
        "promotionalText": PROMO_EN,
        "description": DESC_EN,
        "whatsNew": WHATS_NEW_EN,
    },
    "ru": {
        "name": "Non Bank: расходы и счета",
        "subtitle": "Делите счета, сканируйте чеки",
        "keywords": "бюджет,траты,расходы,учет,деньги,долги,поездка,друзья,чек,сплит,общие,финансы,трекер,приватно",
        "promotionalText": ("Приватный учёт расходов и разделение счетов. Без входа в банк, без аккаунта, без рекламы — "
                            "всё хранится на вашем iPhone. Сканируйте чек и делите его по позициям."),
        "description": """Non Bank — приватный учёт расходов и разделение счетов с друзьями. Без подключения банка, без аккаунта, без рекламы: транзакции, друзья и чеки хранятся на вашем iPhone и синхронизируются только через ваш собственный iCloud. Мы их не видим.

ДЕЛИТЕ СЧЕТА ПРОСТО
• Поровну, точными суммами или по позициям
• Отсканируйте чек и разделите его построчно
• Баланс «кто кому должен» и расчёт в одно касание
• Поделитесь сплитом с другом — его копия обновится сама, с шифрованием

ВЕДИТЕ УЧЁТ
• Расходы и доходы за секунды
• Свои категории и эмодзи
• Понятная аналитика, куда уходят деньги
• Повторяющиеся операции и напоминания
• Несколько валют по курсу дня

ПРИВАТНОСТЬ ПО УМОЛЧАНИЮ
• Данные не покидают устройство, кроме вашего iCloud
• Без регистрации и почты
• Экспорт в CSV или JSON в любой момент

Идеи и пожелания: nonbankapp@gmail.com""",
        "whatsNew": ("• Обновлённая страница в App Store\n"
                     "• Приложение может один раз попросить оценку после сплита\n"
                     "• Баланс с другом учитывает только движение денег между вами"),
    },
    "es-MX": {
        "name": "Non Bank: Gastos y Cuentas",
        "subtitle": "Divide cuentas y tickets",
        "keywords": "gastos,presupuesto,dividir,cuentas,amigos,viaje,deudas,recibo,dinero,bill,splitter,expense,budget",
        "promotionalText": ("Control de gastos privado y divisor de cuentas. Sin acceso al banco, sin cuenta, sin anuncios: "
                            "todo se queda en tu iPhone. Escanea un ticket y divídelo por artículo."),
        "description": """Non Bank es un control de gastos privado y un divisor de cuentas. Sin acceso al banco, sin cuenta, sin anuncios: tus movimientos, amigos y tickets viven en tu iPhone y se sincronizan solo con tu propio iCloud. Nunca los vemos.

DIVIDE CUENTAS FÁCILMENTE
• En partes iguales, por montos exactos o por artículo
• Escanea un ticket y divídelo línea por línea
• Saldo de quién debe a quién y liquida con un toque
• Comparte una división con un amigo: su copia se actualiza sola, cifrada

CONTROLA TU DINERO
• Gastos e ingresos en segundos
• Categorías propias con emoji
• Estadísticas claras de a dónde va tu dinero
• Movimientos recurrentes y recordatorios
• Varias monedas al tipo de cambio del día

PRIVADO POR DISEÑO
• Nada sale de tu dispositivo salvo a tu iCloud
• Sin registro ni correo
• Exporta todo en CSV o JSON cuando quieras

¿Ideas? Escríbenos a nonbankapp@gmail.com""",
        "whatsNew": ("• Página de App Store renovada\n"
                     "• La app puede pedirte una valoración una vez después de dividir una cuenta\n"
                     "• El saldo con un amigo refleja solo el dinero que se movió entre ustedes"),
    },
    "de-DE": {
        "name": "Non Bank: Ausgaben & Teilen",
        "subtitle": "Rechnung teilen, Beleg scannen",
        "keywords": "ausgaben,budget,haushaltsbuch,kosten,teilen,freunde,reise,schulden,geld,finanzen,kassenbon,wg,privat",
        "promotionalText": ("Privates Haushaltsbuch und Rechnungsteiler. Kein Bank-Login, kein Konto, keine Werbung – "
                            "alles bleibt auf deinem iPhone. Beleg scannen und Posten für Posten aufteilen."),
        "description": """Non Bank ist ein privates Haushaltsbuch und Rechnungsteiler. Kein Bank-Login, kein Konto, keine Werbung: Buchungen, Freunde und Belege bleiben auf deinem iPhone und werden nur über deine eigene iCloud synchronisiert. Wir sehen sie nie.

RECHNUNGEN EINFACH TEILEN
• Gleichmäßig, nach Beträgen oder Position für Position
• Beleg scannen und Zeile für Zeile aufteilen
• Wer schuldet wem – mit einem Tipp begleichen
• Aufteilung mit Freunden teilen – ihre Kopie aktualisiert sich verschlüsselt von selbst

AUSGABEN IM BLICK
• Ausgaben und Einnahmen in Sekunden erfassen
• Eigene Kategorien mit Emoji
• Klare Auswertungen, wohin das Geld geht
• Wiederkehrende Buchungen und Erinnerungen
• Mehrere Währungen zum Tageskurs

PRIVAT BY DESIGN
• Nichts verlässt dein Gerät außer in deine iCloud
• Keine Registrierung, keine E-Mail
• Export als CSV oder JSON jederzeit

Ideen? Schreib an nonbankapp@gmail.com""",
        "whatsNew": ("• Überarbeitete App-Store-Seite\n"
                     "• Die App kann nach einer Aufteilung einmal um eine Bewertung bitten\n"
                     "• Der Saldo mit einem Freund zeigt nur das Geld, das zwischen euch geflossen ist"),
    },
    "fr-FR": {
        "name": "Non Bank: Dépenses & Partage",
        "subtitle": "Partagez l'addition, scannez",
        "keywords": "dépenses,budget,partager,addition,amis,voyage,dettes,argent,finances,ticket,reçu,colocation,privé",
        "promotionalText": ("Suivi de dépenses privé et partage d'addition. Sans connexion bancaire, sans compte, sans pub : "
                            "tout reste sur votre iPhone. Scannez un ticket, partagez-le par article."),
        "description": """Non Bank est un suivi de dépenses privé et un outil de partage d'addition. Sans connexion bancaire, sans compte, sans pub : vos opérations, amis et tickets restent sur votre iPhone et se synchronisent uniquement via votre propre iCloud. Nous ne les voyons jamais.

PARTAGEZ L'ADDITION SIMPLEMENT
• À parts égales, par montants exacts ou article par article
• Scannez un ticket et partagez-le ligne par ligne
• Qui doit quoi à qui, et réglez en un geste
• Partagez une note avec un ami : sa copie se met à jour toute seule, chiffrée

SUIVEZ VOTRE ARGENT
• Dépenses et revenus en quelques secondes
• Catégories personnalisées avec emoji
• Des statistiques claires sur où part votre argent
• Opérations récurrentes et rappels
• Plusieurs devises au taux du jour

PRIVÉ PAR CONCEPTION
• Rien ne quitte votre appareil, sauf vers votre iCloud
• Ni inscription ni e-mail
• Export CSV ou JSON à tout moment

Des idées ? Écrivez à nonbankapp@gmail.com""",
        "whatsNew": ("• Page App Store repensée\n"
                     "• L'app peut vous demander une note une fois après un partage\n"
                     "• Le solde avec un ami ne reflète que l'argent échangé entre vous"),
    },
}

LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "promotionalText": 170, "description": 4000, "whatsNew": 4000}


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


def get(path, **params):
    return call("GET", path, params=params)


def patch(kind, rid, attributes=None, relationships=None):
    data = {"type": kind, "id": rid}
    if attributes: data["attributes"] = attributes
    if relationships: data["relationships"] = relationships
    print(f"  PATCH {kind}/{rid}: {json.dumps(attributes or relationships, ensure_ascii=False)[:160]}…")
    if DRY: return {}
    return call("PATCH", f"/{kind}/{rid}", json={"data": data})


def post(kind, attributes, relationships):
    print(f"  POST {kind}: {json.dumps(attributes, ensure_ascii=False)[:160]}…")
    if DRY: return {"data": {"id": "dry-run"}}
    return call("POST", f"/{kind}", json={"data": {"type": kind, "attributes": attributes, "relationships": relationships}})


def validate():
    for loc, fields in LOCALES.items():
        for k, v in fields.items():
            if len(v) > LIMITS[k]:
                raise SystemExit(f"{loc}.{k} is {len(v)} chars, limit {LIMITS[k]}")
    print("copy within limits: " + ", ".join(
        f"{l} name={len(f['name'])} sub={len(f['subtitle'])} kw={len(f['keywords'])}" for l, f in LOCALES.items()))


def app_id():
    return get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]


def versions(app):
    return get(f"/apps/{app}/appStoreVersions", **{"filter[platform]": "IOS", "limit": 10})["data"]


def state_of(v):
    return v["attributes"].get("appVersionState") or v["attributes"].get("appStoreState")


def ensure_version(app):
    for v in versions(app):
        if v["attributes"]["versionString"] == TARGET:
            print(f"version {TARGET} exists ({v['id']}, state {state_of(v)})")
            return v["id"]
    print(f"creating App Store version {TARGET}")
    r = post("appStoreVersions", {"platform": "IOS", "versionString": TARGET},
             {"app": {"data": {"type": "apps", "id": app}}})
    return r["data"]["id"]


def live_promo(app):
    for v in versions(app):
        if state_of(v) in ("READY_FOR_DISTRIBUTION", "READY_FOR_SALE") and v["attributes"]["versionString"] != TARGET:
            print(f"live version {v['attributes']['versionString']}: promotional text (no review needed)")
            for loc in get(f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]:
                if loc["attributes"]["locale"] == "en-US":
                    patch("appStoreVersionLocalizations", loc["id"], {"promotionalText": PROMO_EN})
            return


def editable_app_info(app, attempts=6):
    # Right after a new App Store version is created, ASC takes a few
    # seconds to spawn the matching editable appInfo — poll briefly.
    for n in range(attempts):
        infos = get(f"/apps/{app}/appInfos")["data"]
        for i in infos:
            st = i["attributes"].get("state") or i["attributes"].get("appStoreState")
            if st in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
                return i
        if DRY or n == attempts - 1:
            print("no editable appInfo (states: "
                  + ", ".join(str(i["attributes"].get("state") or i["attributes"].get("appStoreState")) for i in infos)
                  + ")" + (" — expected in dry-run before the version exists" if DRY else " — re-run once the version exists"))
            return None
        time.sleep(5)


def apply_app_info(app):
    info = editable_app_info(app)
    if not info:
        if DRY:
            for locale, f in LOCALES.items():
                print(f"  (planned) {locale}: name={f['name']!r} subtitle={f['subtitle']!r}")
            print(f"  (planned) secondaryCategory={SECONDARY_CATEGORY}")
        return
    print(f"appInfo {info['id']}: name / subtitle / category")
    existing = {l["attributes"]["locale"]: l for l in get(f"/appInfos/{info['id']}/appInfoLocalizations")["data"]}
    for locale, f in LOCALES.items():
        attrs = {"name": f["name"], "subtitle": f["subtitle"]}
        if locale in existing:
            patch("appInfoLocalizations", existing[locale]["id"], attrs)
        else:
            attrs["privacyPolicyUrl"] = PRIVACY_URL
            post("appInfoLocalizations", {"locale": locale, **attrs},
                 {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}})
    patch("appInfos", info["id"], relationships={
        "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}}})


def apply_version_localizations(vid):
    print(f"version {vid}: localizations")
    if vid == "dry-run":
        for locale, f in LOCALES.items():
            print(f"  (planned) {locale}: keywords={f['keywords']!r}")
            print(f"            promo={f['promotionalText'][:80]!r}… description={len(f['description'])} chars, whatsNew={len(f['whatsNew'])} chars")
        return
    existing = {l["attributes"]["locale"]: l
                for l in get(f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]}
    for locale, f in LOCALES.items():
        attrs = {"keywords": f["keywords"], "promotionalText": f["promotionalText"],
                 "description": f["description"], "whatsNew": f["whatsNew"],
                 "marketingUrl": MARKETING_URL, "supportUrl": SUPPORT_URL}
        if locale in existing:
            patch("appStoreVersionLocalizations", existing[locale]["id"], attrs)
        else:
            post("appStoreVersionLocalizations", {"locale": locale, **attrs},
                 {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}})


def attach_build(app, vid):
    builds = get("/builds", **{"filter[app]": app, "filter[preReleaseVersion.version]": TARGET,
                               "sort": "-uploadedDate", "limit": 5})["data"]
    if not builds:
        raise SystemExit(f"no build with version {TARGET} uploaded yet")
    b = builds[0]
    st = b["attributes"].get("processingState")
    print(f"newest {TARGET} build: {b['attributes'].get('version')} ({b['id']}) processing={st}")
    if st != "VALID":
        raise SystemExit("build is still processing — re-run in a few minutes")
    print(f"  PATCH appStoreVersions/{vid}/relationships/build -> {b['id']}")
    if not DRY:
        call("PATCH", f"/appStoreVersions/{vid}/relationships/build",
             json={"data": {"type": "builds", "id": b["id"]}})


def main():
    validate()
    app = app_id()
    print(f"app {app}, target version {TARGET}, mode {MODE}, dry_run {DRY}")
    vid = ensure_version(app)
    if MODE == "attach":
        attach_build(app, vid)
        return
    live_promo(app)
    apply_app_info(app)
    apply_version_localizations(vid)
    print("\ndone. Next: MODE=attach once the build is processed, reorder screenshots in ASC, then Add for Review.")


if __name__ == "__main__":
    main()
