#!/usr/bin/env python3
"""Sync the three marketing reports straight into the mktg schema.

This is the workbook-free path. It imports the pull and compute functions from
the three generators, calls them directly, and writes the results into the
mktg.snap_* tables through PostgREST. It never calls build_workbook(), never
touches Supabase Storage, and does not import run_all_reports.py or
push_history.py.

The snap_* tables are entity-grain detail, not aggregates. Roll-ups belong to
the views (v_influence_by_campaign, v_sourced_by_program,
v_sourced_contacts_by_stage, v_sla_by_status, v_sla_by_owner); this script
never computes or stores them.

  influence  generate_report.py         -> mktg.snap_influence
                                           one row per deal x contact x campaign
  netnew     generate_netnew_report.py  -> mktg.snap_sourced_deal
                                           one row per Net New deal in the window,
                                           tagged is_single_program true or false
                                        -> mktg.snap_sourced_contact
                                           one row per marketing-sourced contact
  sla        generate_sla_report.py     -> mktg.snap_lead_sla
                                           one row per contact in the SLA population

Run bookkeeping:

  mktg.run_log_reports   per-report detail, key (snapshot_date, report). Its
                         metrics jsonb is a display cache for headline tiles
                         only - anything needing a breakdown reads the views.
                         Week-over-week deltas are read back from here.
  mktg.run_log           the whole-day record, one row per snapshot_date,
                         stamped started_at before the first report and
                         finished_at once all have been attempted.

Every row this script writes carries is_seeded = false. Seeded rows belong to
the separate historical-backfill process; that logic is deliberately not here.

Environment
-----------
  SUPABASE_URL            the project URL. Read from config.env or the
                          environment. One name, used everywhere.
  SUPABASE_SERVICE_KEY    service_role key for that project.
  MKTG_SCHEMA             defaults to "mktg".
  HUBSPOT_TOKEN           read from config.env or the environment, as before.

Usage
-----
  python sync_to_mktg.py --selftest         builders vs COLUMNS, no network
  python sync_to_mktg.py --check-schema     our columns vs the live schema
  python sync_to_mktg.py --dry-run --sample 5   compute, print 5 rows, write nothing
  python sync_to_mktg.py --only influence   one report
  python sync_to_mktg.py                    all three
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone

import generate_report as influence
import generate_netnew_report as netnew
import generate_sla_report as sla

HERE = os.path.dirname(os.path.abspath(__file__))

# Filled by init_creds(). config.env is the primary source, matching the three
# generators, with the environment as the fallback - one place for credentials,
# not two.
SB_URL = ""
SB_KEY = ""
SCHEMA = "mktg"

CHUNK = 500

# This script is the live daily sync. The one-time historical backfill is a
# separate process and is the only thing that writes is_seeded = true.
IS_SEEDED = False

# snap_influence has no page-level signal at deal x contact x campaign grain,
# so storefront cannot be classified here. Constant by design, not a gap.
IS_STOREFRONT = False

# vertical / sub_vertical are never null in either table. One rule everywhere,
# so a view can filter on a value rather than on a null test.
UNKNOWN_VERTICAL = "Unknown"


def init_creds(path=None):
    """Resolve Supabase credentials the way the generators resolve theirs:
    config.env first, then the environment. One variable name, SUPABASE_URL -
    deliberately no second name that could silently diverge later."""
    global SB_URL, SB_KEY, SCHEMA
    cfg = influence.load_config(path)
    SB_URL = (cfg.get("SUPABASE_URL") or "").rstrip("/")
    SB_KEY = cfg.get("SUPABASE_SERVICE_KEY") or ""
    SCHEMA = cfg.get("MKTG_SCHEMA", "mktg")
    return SB_URL, SB_KEY, SCHEMA


# ---------------------------------------------------------------------------
# Table contract. COLUMNS is the single source of truth for what we write: the
# row builders assemble exactly these keys, --check-schema diffs exactly these
# names against the live schema, and --selftest asserts the two never drift.
# ---------------------------------------------------------------------------
COLUMNS = {
    "snap_influence": [
        "snapshot_date", "deal_id", "contact_id", "campaign_id", "campaign_name",
        "campaign_type", "even_split_value", "amount_home", "deal_name",
        "company_name", "pipeline", "stage", "close_date", "create_date",
        "is_won", "is_closed", "is_amazon", "is_galco", "is_internal",
        "is_storefront", "is_seeded",
    ],
    "snap_sourced_deal": [
        "snapshot_date", "deal_id", "deal_name", "amount_home", "pipeline",
        "stage", "close_date", "create_date", "company_id", "company_name",
        "owner_id", "owner_name", "vertical", "sub_vertical", "program",
        "is_single_program", "is_closed_won", "is_closed", "is_amazon",
        "is_galco", "is_seeded",
    ],
    "snap_sourced_contact": [
        "snapshot_date", "contact_id", "email", "create_date", "lifecycle_stage",
        "num_campaigns", "programs", "influenced_value", "owner_id",
        "owner_name", "vertical", "sub_vertical", "is_amazon", "is_internal",
        "is_seeded",
    ],
    "snap_lead_sla": [
        "snapshot_date", "contact_id", "contact_name", "email", "company_name",
        "owner_id", "owner_name", "lead_status", "lifecycle_stage",
        "entered_status_date", "status_change_source", "days_in_status",
        "days_in_lifecycle_stage", "days_since_last_change", "over_sla",
        "sla_days", "is_seeded",
    ],
    "run_log_reports": [
        "snapshot_date", "report", "generated_at", "status", "row_count",
        "metrics", "is_seeded",
    ],
    "run_log": [
        "snapshot_date", "started_at", "finished_at", "status", "reports_run",
        "reports_failed", "rows_written", "notes", "is_seeded",
    ],
}

ON_CONFLICT = {
    "snap_influence":       "snapshot_date,deal_id,contact_id,campaign_id",
    "snap_sourced_deal":    "snapshot_date,deal_id",
    "snap_sourced_contact": "snapshot_date,contact_id",
    "snap_lead_sla":        "snapshot_date,contact_id",
    "run_log_reports":      "snapshot_date,report",
    "run_log":              "snapshot_date",
}


# ------------------------------------------------------------- postgrest -----
def _require_creds():
    missing = []
    if not SB_URL:
        missing.append("SUPABASE_URL")
    if not SB_KEY:
        missing.append("SUPABASE_SERVICE_KEY")
    if missing:
        sys.exit("No Supabase credentials in config.env or the environment. "
                 "Set: " + ", ".join(missing))


def _request(url, method="GET", body=None, headers=None, timeout=120):
    req = urllib.request.Request(url, data=body, method=method,
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:400]
        raise RuntimeError("%s %s -> %s %s" % (method, url, e.code, detail))
    except urllib.error.URLError as e:
        raise RuntimeError("%s %s -> network %s" % (method, url, e.reason))


def sb_select(table, query=""):
    """Read rows from the mktg schema. Accept-Profile selects the schema."""
    url = "%s/rest/v1/%s%s" % (SB_URL, table, ("?" + query) if query else "")
    return _request(url, headers={
        "apikey": SB_KEY,
        "Authorization": "Bearer " + SB_KEY,
        "Accept": "application/json",
        "Accept-Profile": SCHEMA,
    }) or []


def sb_upsert(table, rows, dry_run=False, sample=2):
    """Insert or replace rows in the mktg schema.

    Content-Profile targets the schema; resolution=merge-duplicates makes a
    same-day re-run overwrite that day rather than fail on the primary key."""
    rows = [r for r in rows if r]
    if not rows:
        print("     skip   %s: nothing to send" % table)
        return 0
    if dry_run:
        print("     dry    %s: %d row(s)" % (table, len(rows)))
        for r in rows[:sample]:
            print("            " + json.dumps(r, default=str))
        if len(rows) > sample:
            print("            ... %d more" % (len(rows) - sample))
        return len(rows)

    on_conflict = ON_CONFLICT.get(table)
    sent = 0
    for i in range(0, len(rows), CHUNK):
        batch = rows[i:i + CHUNK]
        q = "?on_conflict=%s" % urllib.parse.quote(on_conflict) if on_conflict else ""
        url = "%s/rest/v1/%s%s" % (SB_URL, table, q)
        _request(url, method="POST", body=json.dumps(batch, default=str).encode(),
                 headers={
                     "apikey": SB_KEY,
                     "Authorization": "Bearer " + SB_KEY,
                     "Content-Type": "application/json",
                     "Content-Profile": SCHEMA,
                     "Prefer": "resolution=merge-duplicates,return=minimal",
                 })
        sent += len(batch)
    print("     ok     %s: %d row(s)" % (table, sent))
    return sent


# ------------------------------------------------------------- run_log -------
def read_prior(report):
    """Previous run's headline for this report, from mktg.run_log_reports.

    Returns the stored metrics dict, or None on the first ever run. A missing
    prior is not an error - it just means no week-over-week line this time."""
    q = ("report=eq.%s&select=snapshot_date,generated_at,metrics"
         "&order=snapshot_date.desc&limit=1" % urllib.parse.quote(report))
    try:
        rows = sb_select("run_log_reports", q)
    except RuntimeError as e:
        print("     warn   prior lookup failed, continuing without deltas: %s" % e)
        return None
    if not rows:
        return None
    return rows[0].get("metrics") or None


def delta(current, prior, keys):
    """Absolute and percent change per key. Printed for context, not stored -
    metrics stays a display cache of current values only."""
    if not prior:
        return {}
    out = {}
    for k in keys:
        now, was = current.get(k), prior.get(k)
        if isinstance(now, (int, float)) and isinstance(was, (int, float)):
            out[k] = {
                "prior": was,
                "change": round(now - was, 2),
                "pct_change": (round((now - was) / was * 100, 2) if was else None),
            }
    return out


def write_report_log(report, snapshot_date, generated_at, metrics, row_count,
                     status="ok", dry_run=False):
    """Per-report detail row. This is what read_prior() reads back next run."""
    return sb_upsert("run_log_reports", [{
        "snapshot_date": snapshot_date,
        "report": report,
        "generated_at": generated_at,
        "status": status,
        "row_count": row_count,
        "metrics": metrics,
        "is_seeded": IS_SEEDED,
    }], dry_run=dry_run)


def open_day_log(snapshot_date, started_at):
    """Every snap_* table and run_log_reports carries a foreign key to
    run_log.snapshot_date, so the day row has to exist before anything else can
    be written. Opened as "running" here and rewritten with real numbers by
    write_day_log once every report has been attempted."""
    return sb_upsert("run_log", [{
        "snapshot_date": snapshot_date,
        "started_at": started_at,
        "finished_at": None,
        "status": "running",
        "reports_run": 0,
        "reports_failed": 0,
        "rows_written": 0,
        "notes": None,
        "is_seeded": IS_SEEDED,
    }])


def write_day_log(snapshot_date, started_at, finished_at, reports_run,
                  reports_failed, rows_written, notes=None, dry_run=False):
    """The whole-day record: one row per snapshot_date, written once after all
    reports have been attempted. Carries no per-report headline - that lives in
    run_log_reports."""
    if reports_failed == 0:
        status = "ok"
    elif reports_failed < reports_run:
        status = "partial"
    else:
        status = "failed"
    return sb_upsert("run_log", [{
        "snapshot_date": snapshot_date,
        "started_at": started_at,
        "finished_at": finished_at,
        "status": status,
        "reports_run": reports_run,
        "reports_failed": reports_failed,
        "rows_written": rows_written,
        "notes": notes or None,
        "is_seeded": IS_SEEDED,
    }], dry_run=dry_run)


# ---------------------------------------------------------------- helpers ----
def _num(v):
    """The generators write "" where a value is absent, for the workbook's
    benefit. Postgres wants null."""
    return v if isinstance(v, (int, float)) else None


def _date(v):
    return v or None


INTERNAL_DOMAIN = "multisensorai.com"


def _is_internal(email):
    """A contact is internal when their email is on the company domain."""
    return (email or "").strip().lower().endswith("@" + INTERNAL_DOMAIN)


# ----------------------------------------------------- row builders ----------
def rows_influence(snapshot_date, ds):
    """One row per deal x contact x campaign.

    even_split_value is the deal's home-currency amount divided by the size of
    the union of campaigns across ALL of that deal's influenced contacts. It is
    repeated unchanged on every row for that deal and never divided again per
    contact - the ratified definition. The per-deal union and share are built
    exactly as compute_campaign_summary builds them, from the same pair_rows.
    v_influence_by_campaign collapses to one row per (deal, campaign) before
    summing, so the repetition does not inflate campaign totals."""
    deals = ds["deals"]
    cc = ds["contact_campaigns"]
    camp_ids = {l["name"]: str(l["listId"]) for l in ds["lists"]}

    deal_contacts = defaultdict(set)
    for did, cid in ds["pair_rows"]:
        deal_contacts[did].add(cid)

    out = []
    for did, cids in deal_contacts.items():
        union = set()
        for cid in cids:
            union |= cc[cid]
        if not union:
            continue
        d = deals[did]
        # Full precision on purpose: rounding per row and then summing drifts
        # from the ratified total. Round at display time, not here.
        share = d["amount_home"] / len(union)
        company = ds["deal_company_name"](did)
        amazon = netnew.is_amazon(company) or netnew.is_amazon(d["name"])
        galco = netnew.is_galco(company) or netnew.is_galco(d["name"])
        for cid in sorted(cids):
            for camp in sorted(cc[cid]):
                out.append({
                    "snapshot_date": snapshot_date,
                    "deal_id": did,
                    "contact_id": cid,
                    "campaign_id": camp_ids.get(camp),
                    "campaign_name": camp,
                    "campaign_type": influence.classify_campaign(camp),
                    "even_split_value": share,
                    "amount_home": round(d["amount_home"], 2),
                    "deal_name": d["name"],
                    "company_name": company,
                    "pipeline": d["pipeline"],
                    "stage": d["stage"],
                    "close_date": _date(d["close"]),
                    "create_date": _date(d["create"]),
                    "is_won": d["won"],
                    "is_closed": d["closed"],
                    "is_amazon": amazon,
                    "is_galco": galco,
                    "is_internal": _is_internal(ds["cemail"](cid)),
                    # There is no page-level signal at this grain to classify
                    # on, so this is constant here by design, like is_seeded.
                    "is_storefront": IS_STOREFRONT,
                    "is_seeded": IS_SEEDED,
                })
    return out


def rows_sourced_deal(snapshot_date, ds, owners):
    """One row per Net New deal in the window - the full population, each
    tagged is_single_program, so the views can filter rather than assume."""
    out = []
    for did, d in ds["deals"].items():
        oid = str(d.get("owner_id") or "")
        out.append({
            "snapshot_date": snapshot_date,
            "deal_id": did,
            "deal_name": d["name"],
            "amount_home": round(d["amount"], 2),
            "pipeline": d["pipeline"],
            "stage": d["stage"],
            "close_date": _date(d["close"]),
            "create_date": _date(d["create"]),
            "company_id": d.get("company_id") or None,
            "company_name": d.get("company") or "",
            "owner_id": oid or None,
            "owner_name": owners.get(oid, ""),
            "vertical": d.get("vertical") or UNKNOWN_VERTICAL,
            "sub_vertical": d.get("sub_vertical") or UNKNOWN_VERTICAL,
            "program": d.get("program") or None,
            "is_single_program": bool(d.get("single_program")),
            "is_closed_won": bool(d.get("won")),
            "is_closed": bool(d.get("closed")),
            "is_amazon": bool(d.get("amazon")),
            "is_galco": bool(d.get("galco")),
            "is_seeded": IS_SEEDED,
        })
    return out


def rows_sourced_contact(snapshot_date, ds, owners):
    """One row per marketing-sourced contact: created inside the window and a
    member of at least one Campaign Influence list.

    influenced_value is the total home-currency amount of the Net New deals
    this contact is associated with. It is per-contact and will double-count
    across contacts on a shared deal - de-duplication is the view's job."""
    cc = ds["contact_campaigns"]
    deals = ds["deals"]

    contact_deals = defaultdict(set)
    for did, cids in ds["d2c"].items():
        for cid in cids:
            contact_deals[cid].add(did)

    out = []
    for cid, p in ds["sourced_contacts"].items():
        camps = sorted(cc.get(cid, ()))
        dids = [d for d in contact_deals.get(cid, ()) if d in deals]
        oid = str(p.get("hubspot_owner_id") or "")
        out.append({
            "snapshot_date": snapshot_date,
            "contact_id": cid,
            "email": p.get("email") or "",
            "create_date": _date((p.get("createdate") or "")[:10]),
            "lifecycle_stage": p.get("lifecyclestage") or None,
            "num_campaigns": len(camps),
            # text[] in Postgres, so send a JSON array and let PostgREST cast
            # it. A joined string is rejected as a malformed array literal.
            "programs": sorted({netnew.classify_program(c) for c in camps}),
            "influenced_value": round(sum(deals[d]["amount"] for d in dids), 2),
            "owner_id": oid or None,
            "owner_name": owners.get(oid, ""),
            # industry / primary_subindustry_dropdown are contact properties,
            # so a contact row uses its own values. Same Unknown fallback as
            # snap_sourced_deal - one rule in both tables, never null.
            "vertical": p.get("industry") or UNKNOWN_VERTICAL,
            "sub_vertical": (p.get("primary_subindustry_dropdown")
                             or UNKNOWN_VERTICAL),
            "is_amazon": any(deals[d].get("amazon") for d in dids),
            "is_internal": _is_internal(p.get("email")),
            "is_seeded": IS_SEEDED,
        })
    return out


def rows_lead_sla(snapshot_date, detail_rows, owners):
    """One row per contact in the SLA population, straight off the detail rows
    build_snapshot() already produces.

    days_since_last_change is the smaller of the two ages, matching how
    build_snapshot aggregates it per rep: a smaller age means a more recent
    change."""
    out = []
    for r in detail_rows:
        d_status = _num(r.get("days_status"))
        d_stage = _num(r.get("days_stage"))
        ages = [x for x in (d_status, d_stage) if x is not None]
        entered = r.get("entered")
        oid = str(r.get("owner_id") or "")
        out.append({
            "snapshot_date": snapshot_date,
            "contact_id": r.get("contact_id"),
            "contact_name": r.get("name") or "",
            "email": r.get("email") or "",
            "company_name": r.get("company") or "",
            "owner_id": oid or None,
            "owner_name": owners.get(oid) or r.get("rep") or "",
            # Blank for a contact whose lead_status is not one we track. Null
            # is the honest value there, not false or an empty string.
            "lead_status": r.get("status") or None,
            "lifecycle_stage": r.get("stage") or None,
            "entered_status_date": (entered if entered and entered != "(no history)"
                                    else None),
            "status_change_source": r.get("src") or None,
            "days_in_status": d_status,
            "days_in_lifecycle_stage": d_stage,
            "days_since_last_change": min(ages) if ages else None,
            "over_sla": (None if not r.get("over") else r.get("over") == "YES"),
            "sla_days": r.get("sla"),
            "is_seeded": IS_SEEDED,
        })
    return out


# ------------------------------------------------------------- runners -------
def _report_delta(name, headline, keys, dry_run):
    prior = read_prior(name) if not dry_run else None
    d = delta(headline, prior, keys)
    if d:
        print("     wow    %s" % json.dumps(d, default=str))
    return d


def run_influence(snapshot_date, generated_at, dry_run=False, sample=2):
    print("[influence] pulling HubSpot ...")
    influence.init()
    ds = influence.build_dataset()

    rows = rows_influence(snapshot_date, ds)
    # Display cache only: enough for a headline tile, nothing granular.
    headline = {
        "influenced_deals": len(ds["influenced_deal_ids"]),
        "influenced_pipeline": round(ds["influenced_value"], 2),
    }
    _report_delta("influence", headline, list(headline), dry_run)

    n = sb_upsert("snap_influence", rows, dry_run=dry_run, sample=sample)
    write_report_log("influence", snapshot_date, generated_at, headline, n,
                     dry_run=dry_run)
    return headline, n


def run_netnew(snapshot_date, generated_at, dry_run=False, sample=2):
    print("[netnew] pulling HubSpot ...")
    netnew.init()
    sla.init()
    owners = sla.fetch_owners()
    ds = netnew.build_dataset()
    dg = netnew.compute_deal_grain(ds)

    headline = {
        "sourced_deals": len(dg["single_rows"]),
        "sourced_pipeline": round(sum(d["amount"] for d in dg["single_rows"]), 2),
    }
    _report_delta("netnew", headline, list(headline), dry_run)

    n = sb_upsert("snap_sourced_deal",
                  rows_sourced_deal(snapshot_date, ds, owners),
                  dry_run=dry_run, sample=sample)
    n += sb_upsert("snap_sourced_contact",
                   rows_sourced_contact(snapshot_date, ds, owners),
                   dry_run=dry_run, sample=sample)
    write_report_log("netnew", snapshot_date, generated_at, headline, n,
                     dry_run=dry_run)
    return headline, n


def run_sla(snapshot_date, generated_at, dry_run=False, sample=2):
    print("[sla] pulling HubSpot ...")
    sla.init()
    owners = sla.fetch_owners()
    snap, detail = sla.build_snapshot()

    by_status = {k: v["over"] for k, v in snap["headline"].items()}
    headline = {
        "contacts_over_sla": sum(by_status.values()),
        "over_sla_by_status": by_status,
    }
    _report_delta("sla", headline, ["contacts_over_sla"], dry_run)

    n = sb_upsert("snap_lead_sla",
                  rows_lead_sla(snapshot_date, detail, owners),
                  dry_run=dry_run, sample=sample)
    write_report_log("sla", snapshot_date, generated_at, headline, n,
                     dry_run=dry_run)
    return headline, n


# -------------------------------------------------------- schema check -------
def check_schema():
    """Diff COLUMNS against what the live mktg schema actually has."""
    init_creds()
    _require_creds()
    spec = _request("%s/rest/v1/" % SB_URL, headers={
        "apikey": SB_KEY,
        "Authorization": "Bearer " + SB_KEY,
        "Accept": "application/openapi+json",
        "Accept-Profile": SCHEMA,
    })
    defs = (spec or {}).get("definitions", {})
    if not defs:
        print("No table definitions came back for schema %r. Check that the "
              "schema exists and is in the project's exposed schemas list "
              "(Settings > API > Exposed schemas)." % SCHEMA)
        return 1

    # The spec above comes from PostgREST's schema cache and is readable
    # without any privilege on the schema, so a clean column diff says nothing
    # about whether we can actually read or write. Probe before reporting.
    try:
        sb_select("run_log", "limit=1")
        print("access: %s.run_log readable" % SCHEMA)
    except RuntimeError as e:
        msg = str(e)
        print("access: FAILED - %s" % msg[-160:])
        if "42501" in msg or "permission denied" in msg:
            print("")
            print("The schema is exposed to the API but the role has no rights on")
            print("it. Exposing a schema in Settings > API does not grant Postgres")
            print("privileges. Run this once in the SQL editor:")
            print("")
            print("  grant usage on schema %s to service_role;" % SCHEMA)
            print("  grant all on all tables in schema %s to service_role;" % SCHEMA)
            print("  grant all on all sequences in schema %s to service_role;" % SCHEMA)
            print("  alter default privileges in schema %s" % SCHEMA)
            print("    grant all on tables to service_role;")
        return 1

    problems = 0
    for table, cols in COLUMNS.items():
        print("")
        print("%s.%s" % (SCHEMA, table))
        if table not in defs:
            print("  MISSING - no such table in this schema")
            problems += 1
            continue
        actual = set(defs[table].get("properties", {}))
        want = set(cols)
        bad = sorted(want - actual)
        unused = sorted(actual - want)
        if bad:
            print("  we send columns that do NOT exist: %s" % ", ".join(bad))
            problems += 1
        else:
            print("  all %d columns exist" % len(want))
        if unused:
            print("  table also has (we never write): %s" % ", ".join(unused))
    print("")
    print("Schema matches." if not problems
          else "%d table(s) still mismatched." % problems)
    return 1 if problems else 0


def _selftest():
    """Assert every builder emits exactly the keys COLUMNS declares, so the
    schema check can never pass while the builders write something else."""
    sd = "2026-09-01"
    ds_inf = {
        "deals": {"D1": {"id": "D1", "name": "Deal One", "amount": 900.0,
                         "amount_home": 900.0, "pipeline": "P", "stage": "S",
                         "close": "2026-10-01", "create": "2026-08-01",
                         "won": False, "closed": False}},
        "contact_campaigns": {"C1": {"Campaign Influence - Webinar"},
                              "C2": {"Campaign Influence - Webinar",
                                     "Campaign Influence - Events"}},
        "pair_rows": [("D1", "C1"), ("D1", "C2")],
        "lists": [{"name": "Campaign Influence - Webinar", "listId": 11},
                  {"name": "Campaign Influence - Events", "listId": 22}],
        "deal_company_name": lambda d: "Acme Co",
        "cemail": lambda c: {"C1": "buyer@acme.com",
                             "C2": "alecia@multisensorai.com"}.get(c, ""),
    }
    ds_nn = {
        "deals": {"D1": {"name": "D", "amount": 100.0, "pipeline": "P", "stage": "S",
                         "close": "", "create": "2026-08-01", "company_id": "CO1",
                         "company": "Acme", "owner_id": "77", "vertical": "Logistics",
                         "sub_vertical": "Parcel", "program": "Events",
                         "single_program": True, "won": True, "closed": True,
                         "amazon": False, "galco": False}},
        "contact_campaigns": {"C1": {"Campaign Influence - Events"}},
        "d2c": {"D1": ["C1"]},
        "sourced_contacts": {"C1": {"email": "a@b.com", "createdate": "2026-08-02",
                                    "lifecyclestage": "lead",
                                    "hubspot_owner_id": "77",
                                    "industry": "Logistics",
                                    "primary_subindustry_dropdown": "Parcel"}},
    }
    detail = [{"contact_id": "C9", "owner_id": "77", "status": "Qualified",
               "sla": 14.0, "name": "A B", "email": "a@b.com", "company": "Acme",
               "rep": "Rep", "stage": "MQL", "entered": "(no history)", "src": "",
               "days_status": 3.2, "days_stage": ""}]
    owners = {"77": "Dana Rep"}

    checks = [
        ("snap_influence", rows_influence(sd, ds_inf)),
        ("snap_sourced_deal", rows_sourced_deal(sd, ds_nn, owners)),
        ("snap_sourced_contact", rows_sourced_contact(sd, ds_nn, owners)),
        ("snap_lead_sla", rows_lead_sla(sd, detail, owners)),
    ]
    ok = True
    for table, rows in checks:
        got, want = set(rows[0]), set(COLUMNS[table])
        if got != want:
            ok = False
            print("MISMATCH %s: extra=%s missing=%s"
                  % (table, sorted(got - want), sorted(want - got)))
        else:
            print("ok   %-22s %d row(s), %d columns" % (table, len(rows), len(got)))

    inf = checks[0][1]
    print("")
    print("influence grain: %d rows from 1 deal, 2 contacts, union of 2 campaigns"
          % len(inf))
    print("  900.00 / 2 campaigns in union = 450.0 expected")
    print("  even_split_value values present: %s"
          % sorted({r["even_split_value"] for r in inf}))
    for r in inf:
        print("    %s x %s x %-35s %s"
              % (r["deal_id"], r["contact_id"], r["campaign_name"],
                 r["even_split_value"]))
    c = checks[2][1][0]
    print("")
    print("contact vertical/sub_vertical: %r / %r ; is_internal=%r"
          % (c["vertical"], c["sub_vertical"], c["is_internal"]))
    print("influence is_internal by contact: %s"
          % sorted({(r["contact_id"], r["is_internal"]) for r in inf}))
    print("influence is_storefront: %s" % sorted({r["is_storefront"] for r in inf}))

    s = checks[3][1][0]
    print("")
    print("sla null handling: entered_status_date=%r days_in_lifecycle_stage=%r "
          "days_since_last_change=%r owner_name=%r"
          % (s["entered_status_date"], s["days_in_lifecycle_stage"],
             s["days_since_last_change"], s["owner_name"]))
    return 0 if ok else 1


# ----------------------------------------------------------------- main ------
def main():
    ap = argparse.ArgumentParser(
        description="Sync report detail into the mktg schema.")
    ap.add_argument("--only", choices=["influence", "netnew", "sla"],
                    help="run one report instead of all three")
    ap.add_argument("--dry-run", action="store_true",
                    help="compute and print payloads, write nothing")
    ap.add_argument("--sample", type=int, default=2,
                    help="rows to print per table under --dry-run (default 2)")
    ap.add_argument("--check-schema", action="store_true",
                    help="diff our columns against the live mktg schema, then exit")
    ap.add_argument("--selftest", action="store_true",
                    help="verify builders match COLUMNS using fixtures, then exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(_selftest())
    if args.check_schema:
        sys.exit(check_schema())

    init_creds()
    if not args.dry_run:
        _require_creds()
        print("target: %s schema %r" % (SB_URL, SCHEMA))
    else:
        print("DRY RUN - computing from HubSpot, writing nothing")

    started = datetime.now(timezone.utc)
    snapshot_date, gen_at = started.strftime("%Y-%m-%d"), started.isoformat()

    jobs = [("influence", run_influence), ("netnew", run_netnew), ("sla", run_sla)]
    if args.only:
        jobs = [j for j in jobs if j[0] == args.only]

    # Must come first: the foreign keys make every other write depend on it.
    if not args.dry_run:
        print("[day] opening run_log row ...")
        try:
            open_day_log(snapshot_date, gen_at)
        except Exception as e:
            sys.exit("Could not open the run_log row for %s. Nothing else can "
                     "be written while it is missing: %s" % (snapshot_date, e))

    failures, rows_written, notes = 0, 0, []
    for name, fn in jobs:
        try:
            head, n = fn(snapshot_date, gen_at, dry_run=args.dry_run,
                         sample=args.sample)
            rows_written += n
            print("     headline: %s" % json.dumps(head, default=str)[:300])
        except Exception as e:
            failures += 1
            notes.append("%s failed: %s" % (name, str(e)[:120]))
            print("FAIL   %s: %s" % (name, e), file=sys.stderr)

    print("[day] closing run_log row ...")
    day_failed = False
    try:
        write_day_log(snapshot_date, gen_at,
                      datetime.now(timezone.utc).isoformat(),
                      len(jobs), failures, rows_written,
                      notes="; ".join(notes) if notes else None,
                      dry_run=args.dry_run)
    except Exception as e:
        day_failed = True
        print("FAIL   run_log day row: %s" % e, file=sys.stderr)

    print("")
    print("%d of %d report(s) synced." % (len(jobs) - failures, len(jobs)))
    if day_failed:
        print("run_log day row was not written.")
    sys.exit(1 if (failures or day_failed) else 0)


if __name__ == "__main__":
    main()
