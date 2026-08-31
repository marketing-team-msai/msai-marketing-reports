#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MultiSensor AI marketing reporting - daily runner.

This is the single entry point the scheduled task calls. It runs the three
report generators, then publishes the output to the Marketing Team SharePoint
site.

Cadence:
    workbooks  every day

PowerPoint decks were retired 31 August 2026. Excel workbooks only.

Layout it maintains, per report, identical on either target:

    <root>/<Report Name>/
        <fixed filename>          always the newest run, this is what pages embed
        Archive/
            YYYY-MM-DD_<filename> one dated copy per run, the history

Nothing is ever deleted. The fixed-name copy is overwritten in place so that
links and embedded web parts never go stale.

Usage
    python run_all_reports.py                 normal scheduled run
    python run_all_reports.py --dry-run       run generators, skip the upload
    python run_all_reports.py --only sla      run one report (influence|netnew|sla)

Exit code is 0 only if every report generated and published.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
GEN_DIR = os.environ.get("MSAI_GEN_DIR", HERE)
OUTDIR = os.path.join(GEN_DIR, "output")
LOGDIR = os.path.join(GEN_DIR, "logs")


# Load config.env into the environment so the SharePoint upload can find its
# Microsoft credentials. This is the same file the report generators already
# read for their HubSpot and Windsor keys. A real environment variable, if one
# is ever set, takes precedence over the file (setdefault does not overwrite).
def _load_config_env(path=None):
    path = path or os.path.join(HERE, "config.env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


_load_config_env()

# Where the workbooks get published. Set PUBLISH_TARGET to:
#   supabase    Supabase Storage only (the default, no IT dependency)
#   sharepoint  the Marketing SharePoint site only (the original setup)
#   both        publish to both
PUBLISH_TARGET = os.environ.get("PUBLISH_TARGET", "supabase").strip().lower()

# ---- Supabase Storage ----
SB_URL = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
SB_KEY = os.environ.get("SUPABASE_SERVICE_KEY") or ""
SB_BUCKET = os.environ.get("SUPABASE_BUCKET", "reports")
# How long the shareable links printed in the log stay valid, in days.
SB_LINK_DAYS = int(os.environ.get("SUPABASE_LINK_DAYS", "7"))

# ---- Microsoft Graph / SharePoint ----
GRAPH = "https://graph.microsoft.com/v1.0"
SITE_ID = os.environ.get(
    "MSAI_SITE_ID",
    "multisensorai.sharepoint.com,720300ee-d891-4a59-af36-815c47746199,"
    "9bf8ac4d-b292-4609-b9ad-ee38972f0432",
)
SP_ROOT = os.environ.get("MSAI_SP_ROOT", "Reports/Automated Reporting")

# report key -> (display name, generator script, workbook)
REPORTS = {
    "influence": (
        "Pipeline Influence",
        "generate_report.py",
        "MSAI_Pipeline_Influence_Report.xlsx",
    ),
    "netnew": (
        "Marketing Net New and Sourced",
        "generate_netnew_report.py",
        "MSAI_NetNew_Sourced_Report.xlsx",
    ),
    "sla": (
        "Lead Pipeline SLA",
        "generate_sla_report.py",
        "MSAI_Lead_Pipeline_SLA.xlsx",
    ),
}


# --------------------------------------------------------------- logging ----
def log(msg):
    line = "%s  %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        stamp = datetime.now().strftime("%Y-%m")
        with open(os.path.join(LOGDIR, "run-%s.log" % stamp), "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


# ------------------------------------------------------------ generators ----
def run_generator(key):
    name, script, _ = REPORTS[key]
    path = os.path.join(GEN_DIR, script)
    if not os.path.exists(path):
        log("FAIL   %s: %s not found" % (name, script))
        return False

    python = sys.executable
    started = time.time()
    log("run    %s" % name)
    proc = subprocess.run([python, path], cwd=GEN_DIR,
                          capture_output=True, text=True, timeout=3600)
    took = int(time.time() - started)

    if proc.returncode != 0:
        log("FAIL   %s after %ds, exit %d" % (name, took, proc.returncode))
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-8:]
        for t in tail:
            log("       | %s" % t)
        return False

    log("ok     %s in %ds" % (name, took))
    return True


# ----------------------------------------------------------------- graph ----
def get_token():
    """Return a Graph access token.

    Two supported modes, checked in order:

      1. Client credentials, the right answer for an unattended machine.
         Set MSAI_TENANT_ID, MSAI_CLIENT_ID and MSAI_CLIENT_SECRET.

      2. A delegated refresh token in MSAI_REFRESH_TOKEN, for running by hand.
         Note the refresh token rotates on use, so this is not for a scheduled
         job on more than one machine.
    """
    tenant = os.environ.get("MSAI_TENANT_ID")
    cid = os.environ.get("MSAI_CLIENT_ID")
    secret = os.environ.get("MSAI_CLIENT_SECRET")
    refresh = os.environ.get("MSAI_REFRESH_TOKEN")

    if cid and secret and tenant:
        url = "https://login.microsoftonline.com/%s/oauth2/v2.0/token" % tenant
        body = urllib.parse.urlencode({
            "client_id": cid,
            "client_secret": secret,
            "grant_type": "client_credentials",
            "scope": "https://graph.microsoft.com/.default",
        }).encode()
    elif cid and refresh:
        url = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        body = urllib.parse.urlencode({
            "client_id": cid,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        }).encode()
    else:
        raise SystemExit(
            "No SharePoint credentials. Set MSAI_TENANT_ID, MSAI_CLIENT_ID and "
            "MSAI_CLIENT_SECRET (preferred), or MSAI_CLIENT_ID and "
            "MSAI_REFRESH_TOKEN."
        )

    req = urllib.request.Request(url, data=body)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["access_token"]


def api(token, url, method="GET", data=None, ctype=None):
    headers = {"Authorization": "Bearer " + token}
    if ctype:
        headers["Content-Type"] = ctype
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "ignore")[:200]
            if e.code in (429, 503, 504) and attempt < 3:
                time.sleep(3 * (attempt + 1))
                continue
            return {"__err": "%s %s" % (e.code, detail)}
        except urllib.error.URLError as e:
            if attempt < 3:
                time.sleep(3 * (attempt + 1))
                continue
            return {"__err": "network %s" % e.reason}
    return {"__err": "unreachable"}


def q(path):
    return urllib.parse.quote(path)


def ensure_folder(token, path):
    got = api(token, "%s/sites/%s/drive/root:/%s" % (GRAPH, SITE_ID, q(path)))
    if "__err" not in got:
        return True
    parent, _, name = path.rpartition("/")
    url = ("%s/sites/%s/drive/root:/%s:/children" % (GRAPH, SITE_ID, q(parent))) if parent \
        else ("%s/sites/%s/drive/root/children" % (GRAPH, SITE_ID))
    body = json.dumps({"name": name, "folder": {},
                       "@microsoft.graph.conflictBehavior": "fail"}).encode()
    made = api(token, url, method="POST", data=body, ctype="application/json")
    if "__err" in made:
        log("FAIL   folder %s: %s" % (path, made["__err"]))
        return False
    log("made   folder %s" % path)
    return True


def upload(token, local, dest):
    with open(local, "rb") as fh:
        data = fh.read()
    url = "%s/sites/%s/drive/root:/%s:/content" % (GRAPH, SITE_ID, q(dest))
    res = api(token, url, method="PUT", data=data,
              ctype="application/octet-stream")
    if "__err" in res:
        log("FAIL   upload %s: %s" % (dest, res["__err"]))
        return False
    log("put    %s  (%d KB)" % (dest, len(data) // 1024))
    return True


def publish(token, key, stamp):
    name, _, workbook = REPORTS[key]
    base = "%s/%s" % (SP_ROOT, name)
    if not ensure_folder(token, base):
        return False
    if not ensure_folder(token, base + "/Archive"):
        return False

    ok = True
    files = [workbook]
    for fname in files:
        local = os.path.join(OUTDIR, fname)
        if not os.path.exists(local):
            log("FAIL   %s missing from output" % fname)
            ok = False
            continue
        ok &= upload(token, local, "%s/%s" % (base, fname))
        ok &= upload(token, local, "%s/Archive/%s_%s" % (base, stamp, fname))
    return ok


# ------------------------------------------------------ supabase storage ----
# Same layout as the SharePoint one, so nothing about how people find a report
# changes if the target is ever switched:
#
#   <bucket>/<Report Name>/<fixed filename>          newest run, overwritten
#   <bucket>/<Report Name>/Archive/YYYY-MM-DD_<name> one copy per run, kept
#
# The bucket is private. Files are reached through the Supabase dashboard, or
# through a signed link (see sb_signed_url), never a public URL - these
# workbooks carry deal-level pipeline data.
def sb_headers(extra=None):
    h = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY}
    if extra:
        h.update(extra)
    return h


def sb_call(url, method="GET", data=None, ctype=None, extra_headers=None):
    headers = sb_headers(extra_headers)
    if ctype:
        headers["Content-Type"] = ctype
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "ignore")[:200]
            if e.code in (429, 502, 503, 504) and attempt < 3:
                time.sleep(3 * (attempt + 1))
                continue
            return {"__err": "%s %s" % (e.code, detail)}
        except urllib.error.URLError as e:
            if attempt < 3:
                time.sleep(3 * (attempt + 1))
                continue
            return {"__err": "network %s" % e.reason}
    return {"__err": "unreachable"}


def sb_ensure_bucket():
    """Create the private bucket if it is not there yet. Safe every run."""
    got = sb_call("%s/storage/v1/bucket/%s" % (SB_URL, SB_BUCKET))
    if "__err" not in got:
        return True
    body = json.dumps({"id": SB_BUCKET, "name": SB_BUCKET, "public": False}).encode()
    made = sb_call("%s/storage/v1/bucket" % SB_URL, method="POST", data=body,
                   ctype="application/json")
    if "__err" in made:
        log("FAIL   bucket %s: %s" % (SB_BUCKET, made["__err"]))
        return False
    log("made   bucket %s (private)" % SB_BUCKET)
    return True


XLSX_CTYPE = ("application/vnd.openxmlformats-officedocument"
              ".spreadsheetml.sheet")


def sb_upload(local, dest):
    with open(local, "rb") as fh:
        data = fh.read()
    url = "%s/storage/v1/object/%s/%s" % (SB_URL, SB_BUCKET, q(dest))
    # x-upsert lets the fixed-name copy be overwritten in place, which is what
    # keeps its link stable run to run.
    res = sb_call(url, method="POST", data=data, ctype=XLSX_CTYPE,
                  extra_headers={"x-upsert": "true"})
    if "__err" in res:
        log("FAIL   upload %s: %s" % (dest, res["__err"]))
        return False
    log("put    %s  (%d KB)" % (dest, len(data) // 1024))
    return True


def sb_signed_url(dest, days=None):
    """A time-limited download link, for sharing. Returns None on failure -
    a missing link is not a failed publish, so callers only log it."""
    days = days or SB_LINK_DAYS
    url = "%s/storage/v1/object/sign/%s/%s" % (SB_URL, SB_BUCKET, q(dest))
    body = json.dumps({"expiresIn": days * 86400}).encode()
    res = sb_call(url, method="POST", data=body, ctype="application/json")
    if "__err" in res or "signedURL" not in res:
        return None
    return "%s/storage/v1%s" % (SB_URL, res["signedURL"])


def sb_publish(key, stamp):
    name, _, workbook = REPORTS[key]
    local = os.path.join(OUTDIR, workbook)
    if not os.path.exists(local):
        log("FAIL   %s missing from output" % workbook)
        return False

    current = "%s/%s" % (name, workbook)
    archive = "%s/Archive/%s_%s" % (name, stamp, workbook)
    ok = sb_upload(local, current)
    ok &= sb_upload(local, archive)

    if ok:
        link = sb_signed_url(current)
        if link:
            log("link   %s  (%d days)" % (link, SB_LINK_DAYS))
    return ok


# ------------------------------------------------------------------ main ----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="run the generators but do not publish")
    ap.add_argument("--only", choices=sorted(REPORTS),
                    help="run a single report")
    args = ap.parse_args()

    now = datetime.now()
    stamp = now.strftime("%Y-%m-%d")
    log("=" * 62)
    log("MSAI marketing reporting, %s (%s)" % (stamp, now.strftime("%A")))

    keys = [args.only] if args.only else list(REPORTS)

    generated = []
    for key in keys:
        if run_generator(key):
            generated.append(key)

    if args.dry_run:
        log("dry run, nothing published")
        log("generated %d of %d" % (len(generated), len(keys)))
        return 0 if len(generated) == len(keys) else 1

    if not generated:
        log("nothing generated, nothing to publish")
        return 1

    # Publish to whichever targets are configured. A report counts as
    # published only if every configured target accepted it.
    targets = {"supabase": PUBLISH_TARGET in ("supabase", "both"),
               "sharepoint": PUBLISH_TARGET in ("sharepoint", "both")}
    if not any(targets.values()):
        log("PUBLISH_TARGET=%r is not one of supabase, sharepoint, both"
            % PUBLISH_TARGET)
        return 1
    log("publishing to: %s" % ", ".join(t for t, on in targets.items() if on))

    results = {k: True for k in generated}

    if targets["supabase"]:
        if not (SB_URL and SB_KEY):
            log("FAIL   no Supabase credentials. Set SUPABASE_URL and "
                "SUPABASE_SERVICE_KEY.")
            for k in results:
                results[k] = False
        elif not sb_ensure_bucket():
            for k in results:
                results[k] = False
        else:
            for k in generated:
                results[k] &= sb_publish(k, stamp)

    if targets["sharepoint"]:
        token = get_token()
        ensure_folder(token, SP_ROOT)
        for k in generated:
            results[k] &= publish(token, k, stamp)

    published = [k for k in generated if results[k]]

    log("-" * 62)
    log("generated %d/%d, published %d/%d"
        % (len(generated), len(keys), len(published), len(generated)))
    failed = len(keys) - len(published)
    log("OUTCOME items_in=%d items_out=%d failed=%d"
        % (len(keys), len(published), failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
