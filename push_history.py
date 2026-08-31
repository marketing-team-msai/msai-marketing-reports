#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Push this run's report numbers into the Supabase history tables.

This reads the JSON files the three generators already wrote into output/
and upserts them. It does not call HubSpot and it does not recompute
anything, so the numbers in Supabase always match the workbooks exactly.

Runs after run_all_reports.py. If it fails, the workbooks are already in
SharePoint and unaffected. Only the history row is missing, and the next
run will add its own.

Config (from config.env or real environment variables):
    SUPABASE_URL          https://<project-ref>.supabase.co
    SUPABASE_SERVICE_KEY  the service_role key (secret, bypasses RLS)

Usage
    python push_history.py
    python push_history.py --dry-run    print what would be sent, send nothing
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(HERE, "output")


def load_config_env(path=None):
    """Same config.env loader the other scripts use. Real environment
    variables win over the file."""
    path = path or os.path.join(HERE, "config.env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


load_config_env()
SB_URL = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
SB_KEY = os.environ.get("SUPABASE_SERVICE_KEY") or ""


def upsert(table, rows):
    """Insert or replace rows, matching on the primary key of the table.

    resolution=merge-duplicates is what makes a same-day re-run overwrite
    that day instead of failing on a duplicate key.
    """
    rows = [r for r in rows if r]
    if not rows:
        print("skip   %s: nothing to send" % table)
        return 0

    url = "%s/rest/v1/%s" % (SB_URL, table)
    body = json.dumps(rows).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "apikey": SB_KEY,
        "Authorization": "Bearer " + SB_KEY,
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    })
    try:
        with urllib.request.urlopen(req, timeout=120):
            print("ok     %s: %d row(s)" % (table, len(rows)))
            return len(rows)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:300]
        print("FAIL   %s: %s %s" % (table, e.code, detail))
        return -1
    except urllib.error.URLError as e:
        print("FAIL   %s: network %s" % (table, e.reason))
        return -1


def read_json(name):
    path = os.path.join(OUTDIR, name)
    if not os.path.exists(path):
        print("skip   %s not found in output/, that report did not run" % name)
        return None
    with open(path) as fh:
        return json.load(fh)


# --------------------------------------------------- shape the rows ----
def influence_rows(m):
    h = m["headline"]
    total = h.get("total_value") or 0
    pct = round(h["influenced_value"] / total * 100, 2) if total else 0
    head = {
        "run_date": m["run_date"],
        "generated_at": m["generated_at"],
        "label": h.get("label"),
        "total_deals": h.get("total_deals"),
        "total_value": h.get("total_value"),
        "influenced_deals": h.get("influenced_deals"),
        "influenced_value": h.get("influenced_value"),
        "influenced_pct": pct,
        "producing_campaigns": h.get("producing"),
        "multitouch_contacts": h.get("multitouch"),
        "contacts_mapped": h.get("contacts_mapped"),
        "windsor_paid_spend": m.get("windsor_paid_spend"),
    }
    camps = [dict(run_date=m["run_date"], **c) for c in m.get("campaigns", [])]
    return head, camps


def netnew_rows(m):
    head = dict(run_date=m["run_date"], generated_at=m["generated_at"], **m["headline"])
    progs = [dict(run_date=m["run_date"], **p) for p in m.get("programs", [])]
    return head, progs


def sla_rows(snap):
    """The SLA report writes its own, richer snapshot. Take the run date off
    generated_at rather than adding a field to that report."""
    gen = snap["generated_at"]
    run_date = gen[:10]
    head = []
    for status, h in (snap.get("headline") or {}).items():
        head.append({
            "run_date": run_date,
            "lead_status": status,
            "total": h.get("total"),
            "over_sla": h.get("over"),
            "pct_over": h.get("pct_over"),
            "avg_age_days": h.get("avg_age_days"),
            "median_age_days": h.get("median_age_days"),
            "sla_days": h.get("sla_days"),
            "generated_at": gen,
        })
    reps = []
    for owner, by_status in (snap.get("by_rep") or {}).items():
        buckets = by_status.get("sla") if isinstance(by_status, dict) else None
        if not isinstance(buckets, dict):
            buckets = by_status if isinstance(by_status, dict) else {}
        for status, v in buckets.items():
            if not isinstance(v, dict) or "total" not in v:
                continue
            reps.append({
                "run_date": run_date, "owner": owner, "lead_status": status,
                "total": v.get("total"), "over_sla": v.get("over"),
            })
    return run_date, gen, head, reps


# ------------------------------------------------------------- main ----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="print the rows, send nothing")
    args = ap.parse_args()

    if not args.dry_run and not (SB_URL and SB_KEY):
        print("No Supabase credentials. Set SUPABASE_URL and "
              "SUPABASE_SERVICE_KEY in config.env or the environment.")
        return 1

    runs = []
    failures = 0

    inf = read_json("influence_metrics.json")
    if inf:
        head, camps = influence_rows(inf)
        if args.dry_run:
            print(json.dumps({"influence_history": head,
                              "influence_campaign_history_rows": len(camps)},
                             indent=2))
        else:
            failures += 1 if upsert("influence_history", [head]) < 0 else 0
            failures += 1 if upsert("influence_campaign_history", camps) < 0 else 0
            runs.append({"run_date": head["run_date"], "report": "influence",
                         "generated_at": head["generated_at"],
                         "rows_written": 1 + len(camps)})

    nn = read_json("netnew_metrics.json")
    if nn:
        head, progs = netnew_rows(nn)
        if args.dry_run:
            print(json.dumps({"netnew_history": head,
                              "netnew_program_history_rows": len(progs)},
                             indent=2))
        else:
            failures += 1 if upsert("netnew_history", [head]) < 0 else 0
            failures += 1 if upsert("netnew_program_history", progs) < 0 else 0
            runs.append({"run_date": head["run_date"], "report": "netnew",
                         "generated_at": head["generated_at"],
                         "rows_written": 1 + len(progs)})

    sla = read_json("sla_snapshot.json")
    if sla:
        run_date, gen, head, reps = sla_rows(sla)
        if args.dry_run:
            print(json.dumps({"run_date": run_date,
                              "sla_history_rows": len(head),
                              "sla_rep_history_rows": len(reps)}, indent=2))
        else:
            failures += 1 if upsert("sla_history", head) < 0 else 0
            failures += 1 if upsert("sla_rep_history", reps) < 0 else 0
            runs.append({"run_date": run_date, "report": "sla",
                         "generated_at": gen,
                         "rows_written": len(head) + len(reps)})

    if args.dry_run:
        print("dry run, nothing sent")
        return 0

    if runs:
        upsert("report_runs", runs)

    print("HISTORY reports=%d failed=%d" % (len(runs), failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
