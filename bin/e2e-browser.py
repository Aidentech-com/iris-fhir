#!/usr/bin/env python3
"""End-to-end browser test: crg -> CRD card -> DTR -> Keycloak -> questionnaire
-> PriorAuth panel -> PAS $submit -> disposition.

This drives the whole thing in a real browser. bin/demo.sh covers the same
ground over the API but cannot reach the SMART handshake or the Claim that DTR
builds itself from the questionnaire response.

Usage:  ./bin/e2e-browser.py [--headed] [--keep] [--shots DIR]
"""

import argparse
import json
import os
import re
import sys
import time
from urllib.parse import urlparse

try:
    from playwright.sync_api import sync_playwright, expect
except ImportError:
    sys.exit(
        "playwright is not installed. On Ubuntu 24.04 a bare `pip install playwright` is\n"
        "refused (PEP 668, externally managed). Use a venv:\n"
        "  sudo apt-get install -y python3-venv\n"
        "  python3 -m venv .venv\n"
        "  ./.venv/bin/pip install playwright\n"
        "  sudo ./.venv/bin/playwright install --with-deps chromium\n"
        "then run: ADVERTISE_HOST=10.0.3.108 ./.venv/bin/python bin/e2e-browser.py"
    )

CRG = f"http://{os.environ.get('ADVERTISE_HOST', 'localhost')}:3001"
PAS = f"http://{os.environ.get('ADVERTISE_HOST', 'localhost')}:9015/fhir"
KC_USER = "dtr"
KC_PASS = "dtr-demo"

# The form arrives un-prefilled because CRD cannot resolve three CQL expression
# references in HomeBloodGlucoseMonitorRule, so the browser run has to type
# everything the API run gets from bundle-items.json for free.
# LinkIds are the ones the questionnaire marks required.
TEXT_FIELDS = {
    "PBD.1": "Quinton",           # Last Name
    "PBD.2": "Vlad",              # First Name
    "PBD.3": "A",                 # Middle Initial
    "PBD.6": "1EG4-TE5-MK73",     # Medicare ID
    "PND.1": "Fairchild",         # provider last name
    "PND.2": "Peter",
    "PND.3": "H",
    "PND.4": "1234567890",        # NPI
    "5.3": "Contour Next One",    # monitor description
    "SIGPNP.1": "P. H. Fairchild",  # signature
    "SIGPNP.2": "Peter H Fairchild",
    "SIGPNP.4": "1234567890",
}
# Date pickers are ng-zorro <nz-date-picker>, which puts id="<linkId>/1/1" on
# the WRAPPER and leaves the inner input with only a generated class. Targeting
# them by document index silently mis-assigned three of the five (the widget
# re-renders as each one commits, so nth(1..3) were stale by the time they were
# filled). The wrapper id is stable.
DATE_FIELDS = {
    "PBD.4": "12/01/1956",     # Date of Birth
    "PND.5": "09/01/2026",     # Date of F2F encounter
    "3.1": "10/01/2026",       # Start date of order
    "3.2": "10/01/2026",       # Start date
    "SIGPNP.3": "09/27/2026",  # signature date
}
DROPDOWNS = ["5.1", "5.2", "5.4", "6.3"]

# every linkId the questionnaire marks required (HomeBloodGlucoseMonitorOrder)
REQUIRED = [
    "PBD.1", "PBD.2", "PBD.3", "PBD.4", "PBD.6",
    "PND.5", "3.1", "3.2",
    "5.1", "5.2", "5.3", "5.4",
    "6.3",
    "SIGPNP.1", "SIGPNP.2", "SIGPNP.3", "SIGPNP.4",
]

RESULTS = []


def ok(name, detail=""):
    RESULTS.append((True, name, detail))
    print(f"  \033[32mok\033[0m   {name}" + (f"  [{detail}]" if detail else ""))


def bad(name, detail=""):
    RESULTS.append((False, name, detail))
    print(f"  \033[31mFAIL\033[0m {name}" + (f"  [{detail}]" if detail else ""))


def head(title):
    print(f"\n== {title} ==")


class Run:
    def __init__(self, args):
        self.args = args
        self.shots = args.shots
        self.n = 0
        # Start from empty. Numbering restarts at 01 every run, so leftovers from
        # a failed run otherwise sit beside the good ones with the same index
        # ("06-pas-decision.png" and "08-pas-decision.png" from different runs)
        # and the evidence in docs/ becomes unreadable.
        if os.path.isdir(self.shots):
            for f in os.listdir(self.shots):
                os.remove(os.path.join(self.shots, f))
        else:
            os.makedirs(self.shots, exist_ok=True)
        self.console = []
        self.net = []

    def shot(self, page, label):
        self.n += 1
        p = os.path.join(self.shots, f"{self.n:02d}-{label}.png")
        try:
            page.screenshot(path=p, full_page=True)
        except Exception:
            pass
        return p


def wire(page, run):
    page.on("console", lambda m: run.console.append(f"{m.type}: {m.text[:300]}"))
    page.on("request", lambda r: run.net.append(("REQ", r.method, r.url)))
    page.on("response", lambda r: run.net.append(("RES", r.status, r.url)))


TAG_JS = """(pid) => {
    const SEL = 'input[placeholder="Select a request..."]';
    const CAP = 'Click to select this patient';
    const clean = (sel) => document.querySelectorAll(sel)
        .forEach(e => e.removeAttribute(sel.slice(1, -1).split('[')[0]));
    document.querySelectorAll('[data-e2e-info],[data-e2e-tile]')
        .forEach(e => { e.removeAttribute('data-e2e-info');
                        e.removeAttribute('data-e2e-tile'); });

    // The tile is a row: [Patient Info (onClick) | Divider | Request Selection].
    // The caption lives INSIDE the clickable Patient Info box, while the request
    // Autocomplete lives in a SIBLING. So the row is the only common ancestor,
    // and clicking the row's centre hits the Divider, not the handler.
    // Two tags therefore: the row (to find the dropdown) and the Patient Info
    // box (the thing that actually has the onClick).
    const pidEl = [...document.querySelectorAll('*')].find(
        e => e.children.length === 0 && (e.textContent || '').trim() === pid);
    if (!pidEl) return { ok: false, why: 'no element with text ' + pid };

    let row = pidEl, info = null, inp = null;
    while (row && row !== document.body) {
        const t = row.innerText || '';
        if (t.includes(CAP) && row.querySelectorAll(SEL).length === 1) {
            inp = row.querySelector(SEL);
            // innermost ancestor of the caption that is the Patient Info box
            let n = row.querySelector('*');
            let capEl = [...row.querySelectorAll('*')].find(
                e => (e.textContent || '').trim() === CAP);
            info = capEl;
            while (info && info !== row) {
                if ((info.innerText || '').includes('Patient Information')) break;
                info = info.parentElement;
            }
            break;
        }
        row = row.parentElement;
    }
    if (!row || row === document.body) return { ok: false, why: 'no tile row' };
    if (!info) return { ok: false, why: 'no Patient Info box' };
    if ((info.innerText || '').indexOf(pid) < 0) {
        return { ok: false, why: 'Patient Info box is a different patient' };
    }
    row.setAttribute('data-e2e-tile', pid);
    info.setAttribute('data-e2e-info', pid);
    return { ok: true };
}"""


def tag_patient_tile(page, patient_id):
    """Tag the patient's tile row and its clickable Patient Info box.

    Expressing this as a selector is unreliable. A first attempt with
    Playwright's div-filter matched the wrong patient and selected pat015; a
    second attempt tagged the whole grid (its text also contains the target id)
    and the centre-click landed mid-grid. Tagging in JS is unambiguous.
    """
    return page.evaluate(TAG_JS, patient_id)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--headed", action="store_true")
    ap.add_argument("--keep", action="store_true", help="leave the browser open")
    ap.add_argument("--shots", default="docs/screenshots/e2e")
    ap.add_argument("--slow", type=int, default=0)
    args = ap.parse_args()
    run = Run(args)

    with sync_playwright() as pw:
        browser = pw.chromium.launch(
            headless=not args.headed, slow_mo=args.slow, args=["--no-sandbox"]
        )
        ctx = browser.new_context(viewport={"width": 1400, "height": 1000})
        page = ctx.new_page()
        wire(page, run)

        # ---- 1. crg: patient select -------------------------------------
        head("1. crg (:3001) — select pat013 + the glucose order")
        page.goto(CRG + "/", wait_until="networkidle", timeout=90_000)
        page.get_by_text("Patient Select", exact=False).first.click()
        page.wait_for_timeout(1500)
        run.shot(page, "patient-modal")

        tagged = tag_patient_tile(page, "pat013")
        if not tagged.get("ok"):
            bad("pat013 tile found", tagged.get("why", "?"))
            return finish(browser, run, args)
        ok("pat013 tile found")

        # options render as li[role=option] whose label is "<code> (<type>)"
        try:
            page.locator('[data-e2e-tile="pat013"] input[placeholder="Select a request..."]').click()
            page.wait_for_timeout(2500)
            page.locator('li[role="option"]').filter(
                has_text=re.compile(r"E0607\s*\(DeviceRequest\)", re.I)
            ).first.click()
            page.wait_for_timeout(800)
            ok("order selected", "E0607 (DeviceRequest)")
        except Exception as e:
            bad("order selected", str(e)[:160])
            run.shot(page, "order-select-failed")

        # the tile re-renders when the option is chosen, so re-tag it
        tag_patient_tile(page, "pat013")
        page.locator('[data-e2e-info="pat013"]').click()
        page.wait_for_timeout(3000)
        # the assertion must be "the modal closed and the header shows pat013",
        # not "pat013 appears somewhere": the modal itself lists pat013, so a
        # substring check passes whether or not the click did the right thing
        modal_gone = page.locator('input[placeholder="Select a request..."]').count() == 0
        header = page.inner_text("body")
        with open(os.path.join(run.shots, "body-after-select.txt"), "w") as f:
            f.write(header)
        if modal_gone and "Quinton" in header:
            ok("patient selected", "modal closed, header shows Vlad Quinton")
        else:
            bad(
                "patient selected",
                f"modal_gone={modal_gone} header={header[:90]!r}",
            )
            run.shot(page, "patient-select-failed")
            return finish(browser, run, args)

        # ---- 2. CRD card -------------------------------------------------
        head("2. CRD (:8090) — order-sign returns a card")
        try:
            page.get_by_text("Submit to CRD and Display Cards").first.click()
            page.wait_for_timeout(3000)
            page.wait_for_selector("text=Documentation Required", timeout=180_000)
            body = page.inner_text("body")
            ok("card rendered", "Documentation Required")
            if "Home Blood Glucose Monitor" in body:
                ok("card summary", "Home Blood Glucose Monitor")
            else:
                bad("card summary", "summary not found")
        except Exception as e:
            bad("card rendered", str(e)[:160])
            run.shot(page, "card-failed")
            return finish(browser, run, args)
        run.shot(page, "crd-card")

        # ---- 3. DTR launch + Keycloak ------------------------------------
        head("3. SMART launch -> Keycloak (:8180) -> dtr questionnaire")
        dtr = ctx.new_page()
        wire(dtr, run)
        try:
            with ctx.expect_page(timeout=60_000) as newpg:
                page.get_by_text("COMPLETE HOMEBLOODGLUCOSEMONITORORDER", exact=False).first.click()
            dtr = newpg.value
            wire(dtr, run)
            dtr.wait_for_load_state("domcontentloaded")
        except Exception:
            # some builds navigate in the same tab
            dtr = page

        # Keycloak login form?
        try:
            dtr.wait_for_selector("#username", timeout=45_000)
            ok("Keycloak login page", dtr.url.split("/realms/")[-1][:60])
            run.shot(dtr, "keycloak-login")
            dtr.fill("#username", KC_USER)
            dtr.fill("#password", KC_PASS)
            dtr.click("#kc-login")
            dtr.wait_for_load_state("networkidle", timeout=90_000)
            ok("signed in", KC_USER)
        except Exception as e:
            ok("no Keycloak form", "already authenticated or: " + str(e)[:80])

        try:
            dtr.wait_for_selector("#formContainer", timeout=120_000)
            ok("dtr questionnaire rendered", dtr.url[:70])
        except Exception as e:
            bad("dtr questionnaire rendered", str(e)[:160])
            run.shot(dtr, "dtr-failed")
            return finish(browser, run, args)
        dtr.wait_for_timeout(4000)
        run.shot(dtr, "dtr-questionnaire")

        # dump the LForms DOM so the fill logic can target real selectors
        html = dtr.evaluate(
            "() => (document.querySelector('#formContainer')||{}).innerHTML || 'NONE'"
        )
        with open(os.path.join(run.shots, "form-container.html"), "w") as f:
            f.write(html)
        print(f"  ..   form HTML dumped to {run.shots}/form-container.html ({len(html)} bytes)")

        # which questions are actually rendered, and where
        fields = dtr.evaluate(
            """() => {
                const c = document.querySelector('#formContainer');
                if (!c) return [];
                const out = [];
                c.querySelectorAll('input,textarea,select').forEach(e => {
                    // climb to the nearest ancestor that carries question text
                    let n = e, label = '';
                    while (n && n !== c) {
                        const t = (n.innerText||'').trim();
                        if (t && t.length < 200) { label = t.split('\\n')[0]; break; }
                        n = n.parentElement;
                    }
                    out.push({
                        id: e.id || '', tag: e.tagName, type: e.type || '',
                        ph: e.placeholder || '', label: label,
                    });
                });
                return out;
            }"""
        )
        with open(os.path.join(run.shots, "form-fields.json"), "w") as f:
            json.dump(fields, f, indent=1)
        print(f"  ..   {len(fields)} fields -> {run.shots}/form-fields.json")

        # ---- 4. fill the questionnaire -----------------------------------
        head("4. fill the questionnaire (the form arrives un-prefilled)")
        # text fields, by LForms id "<linkId>/1/1"
        for link, val in TEXT_FIELDS.items():
            sel = f'input[id^="{link}"]'
            try:
                dtr.locator(sel).first.fill(val)
            except Exception as e:
                bad(f"fill {link}", str(e)[:80])

        # date fields: the ng-zorro wrapper carries the linkId, the input does not
        for link, val in DATE_FIELDS.items():
            sel = f'nz-date-picker[id^="{link}"] input'
            try:
                inp = dtr.locator(sel).first
                inp.click()
                dtr.wait_for_timeout(200)
                inp.fill(val)
                dtr.wait_for_timeout(200)
                inp.press("Enter")   # nz-date-picker commits on Enter/blur
                dtr.wait_for_timeout(400)
            except Exception as e:
                bad(f"date {link}", str(e)[:90])
        run.shot(dtr, "dates")

        # dropdowns: LForms wraps AjaxAutocomplete, whose popup is
        # .lhc-tools-searchResults. Click the first entry, and if nothing landed
        # fall back to the keyboard path the widget definitely supports.
        for link in DROPDOWNS:
            inp = dtr.locator(f'input[id^="{link}"]').first
            try:
                inp.click()
                dtr.wait_for_timeout(1200)
                picked = dtr.evaluate(
                    """() => {
                        const c = document.querySelector(
                            '.lhc-tools-searchResults');
                        if (!c) return null;
                        const items = [...c.querySelectorAll('li,a,div')].filter(
                            e => e.children.length === 0
                                 && (e.innerText||'').trim());
                        if (!items.length) return null;
                        items[0].click();
                        return items[0].innerText.trim().slice(0, 50);
                    }"""
                )
                dtr.wait_for_timeout(600)
                if not inp.input_value().strip():
                    inp.press("ArrowDown")
                    dtr.wait_for_timeout(400)
                    inp.press("Enter")
                    dtr.wait_for_timeout(600)
                    picked = picked or "(keyboard)"
                print(f"  ..   {link}: picked={picked!r} input={inp.input_value()!r}")
            except Exception as e:
                bad(f"dropdown {link}", str(e)[:100])
        run.shot(dtr, "filled")

        # Verify against the QuestionnaireResponse rather than the widgets.
        # Poking at input values is unreliable: a multi-select autocomplete
        # (6.3 "Time of testing") replaces the input with a selected-list, so
        # the value is never in input_value() even when the answer is recorded.
        answered = dtr.evaluate(
            """() => {
                const d = window.LForms.Util.getFormFHIRData(
                    'QuestionnaireResponse', 'R4', '#formContainer');
                const got = {};
                (function walk(items) {
                    (items || []).forEach(i => {
                        if (i.answer) got[i.linkId] =
                            i.answer.map(a => JSON.stringify(
                                a.valueString ?? a.valueDate ?? a.valueCoding
                                ?.code ?? a.valueBoolean ?? a.valueInteger
                                ?? a)).join('|');
                        walk(i.item);
                    });
                })(d.item);
                return got;
            }"""
        )
        missing = [k for k in REQUIRED if not answered.get(k)]
        if missing:
            bad("every required question answered", f"missing {missing}")
        else:
            ok("every required question answered",
               f"{len(REQUIRED)} required, all present in the QuestionnaireResponse")

        # ---- 5. Proceed To Prior Auth -> DTR builds the Claim -------------
        head("5. dtr builds the Claim and shows the PriorAuth panel")
        try:
            dtr.get_by_text("Proceed To Prior Auth").first.click()
            dtr.wait_for_selector("text=Submit Prior Auth", timeout=60_000)
            ok("PriorAuth panel shown", "DTR replaced the form with the claim panel")
        except Exception as e:
            bad("PriorAuth panel shown", str(e)[:200])
            run.shot(dtr, "priorauth-panel-failed")
            with open(os.path.join(run.shots, "body-at-failure.txt"), "w") as f:
                f.write(dtr.inner_text("body"))
            return finish(browser, run, args)
        run.shot(dtr, "priorauth-panel")

        # PriorAuth.jsx picks its base URL from `window.location.hostname ===
        # "localhost"`, so from a LAN origin it offers the PUBLIC
        # prior-auth.davinci.hl7.org. Point it back at our own PAS.
        dtr_host = urlparse(dtr.url).hostname or "localhost"
        local_pas = f"http://{dtr_host}:9015/fhir"
        ep = dtr.get_by_label("Select PriorAuth Endpoint")
        ep.fill(local_pas)
        ok("PAS endpoint set", local_pas)

        # ---- 6. $submit to PAS -------------------------------------------
        head("6. PAS (:9015) — Claim/$submit from the browser")
        with dtr.expect_response(
            re.compile(r"/Claim/\$submit"), timeout=90_000
        ) as resp:
            dtr.get_by_role("button", name="Submit", exact=True).click()
        r = resp.value
        detail = f"HTTP {r.status}"
        if r.status in (200, 201):
            body = r.json()
            cr = body["entry"][0]["resource"]
            detail += f" disposition={cr.get('disposition')} outcome={cr.get('outcome')}"
            ok("PAS accepted the Claim DTR built", detail)
            preauth = cr["identifier"][0]["value"]
            items = cr.get("item", [])
            ok("ClaimResponse items", f"{len(items)} item(s)")
        else:
            ok("PAS accepted the Claim DTR built", detail + "  <-- rejected")
        run.shot(dtr, "pas-submitted")

        # ---- 7. the async decision ---------------------------------------
        head("7. poll $inquire until the rules engine decides")
        final = None
        for i in range(12):
            dtr.wait_for_timeout(5000)
            try:
                dtr.get_by_role(
                    "button", name=re.compile("Check Claim Status")
                ).first.click()
                dtr.wait_for_timeout(2500)
            except Exception:
                pass
            bodytxt = dtr.inner_text("body")
            # the panel renders "Disposition:" and the value in sibling elements,
            # so inner_text puts a newline between them. The value is title-case
            # ("Pending"), so an [A-Z]+ class would capture only the "P".
            m = re.search(r"Disposition:\s*([A-Za-z]+)", bodytxt)
            if m:
                final = m.group(1)
                print(f"  ..   poll {i+1}: disposition={final}")
                if final.lower() != "pending":
                    break
        if final and final.lower() != "pending":
            ok("decision landed", f"disposition={final}")
        else:
            bad("decision landed", f"final disposition={final}")
        run.shot(dtr, "pas-decision")

        return finish(browser, run, args)


def finish(browser, run, args):
    if not args.keep:
        browser.close()
    npass = sum(1 for r in RESULTS if r[0])
    nfail = len(RESULTS) - npass
    print(f"\n{'PASS' if nfail == 0 else 'FAIL'}  {npass} passed, {nfail} failed")
    interesting = [
        l for l in run.net
        if any(k in l[2] for k in ("Claim/$submit", "questionnaireresponse", "authorize", "token"))
    ]
    if interesting:
        print("\nnetwork of interest:")
        for l in interesting[-25:]:
            print("  ", l)
    if nfail:
        errs = [c for c in run.console if c.startswith(("error", "warning"))]
        if errs:
            print("\nbrowser console (last 20):")
            for e in errs[-20:]:
                print("  ", e)
    sys.exit(0 if nfail == 0 else 1)


if __name__ == "__main__":
    main()
