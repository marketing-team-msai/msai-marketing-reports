#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Events Funnel Report - deterministic generator.

Reproduces, per event, the funnel counts behind Alecia's tradeshow ROI
workbook (Names Captured / Leads / MQLs / SQLs / Opportunities), pulled
live from each event's HubSpot Campaign Influence list rather than typed in
by hand. This script computes counts only; every rate, cost-per-stage
figure, and GOOD/REVIEW or ON BUDGET/OVER BUDGET flag is computed in SQL by
mktg.f_event_roi() from the rows this script writes, plus the hand-entered
mktg.event / mktg.event_cost tables. See
docs/migrations/2026-09-14_events_page.sql for the full schema and why.

What this deliberately does NOT do
-----------------------------------
- No workbook. Unlike the other 3 generators this has no standalone Excel
  output - the only consumer is mktg.snap_event_funnel via sync_to_mktg.py.
- No attendee count. HubSpot carries no attendance data at all; that field
  (mktg.event.actual_attendees) is filled in by hand, same as budget and
  actual cost.
- No dollar figure. Opportunity is a lifecycle stage on the CONTACT record
  here, not a HubSpot Deal - same rule the workbook's Instructions tab
  documents. This script does not join deals, snap_influence, or
  snap_sourced_deal. An "influenced pipeline $" per event is a plausible
  fast-follow (campaign_id in snap_influence already equals
  hubspot_list_id here) but is out of scope for this first cut.
- No event roster of its own. Unlike PROGRAM_KEYWORDS (Python-owned,
  mirrored into config_program_keywords), the event roster is owned by
  mktg.event / mktg.event_hubspot_list - hand-maintained by marketing ops
  in the dashboard itself, not in this file. fetch_event_roster() is this
  script's one exception to "generators never touch Supabase": it has to
  know which events to pull and which HubSpot list(s) each maps to, and
  that lives only in the database.

One event, multiple HubSpot lists
----------------------------------
An event maps to ONE OR MORE HubSpot Campaign Influence lists, not
necessarily one - discovered 2026-09-14 with The Reliability Conference,
which has a separate "Booth" list and "Collateral" list (same event,
different lead-capture channel at the show). This script pulls every list
for an event and takes the UNION of contact ids before bucketing by
lifecycle stage, so a contact who is on both of an event's lists is
counted once, not twice, in names_captured and in whichever stage bucket
they are in. A HubSpot list still belongs to exactly one event
(mktg.event_hubspot_list.hubspot_list_id is UNIQUE) - only the event side
is one-to-many.

Stage bucketing
----------------
Raw HubSpot lifecyclestage values are folded into the 4 funnel buckets
using the same two rules ratified for the workbook on 2026-07-16:

    leads         = 'lead'
    mqls          = 'marketingqualifiedlead'
    sqls          = '157687207' (custom "Sales Accepted Lead" stage id -
                    same portal-specific id already used in
                    generate_netnew_report.LIFECYCLE_ORDER) or
                    'salesqualifiedlead'
    opportunities = 'opportunity' or 'customer' or '1157693063' (Repeat
                    Customer - not in the workbook's documented rule,
                    folded in here for completeness since it is later in
                    the same lifecycle than Customer; flag to Alecia if it
                    should NOT fold in)

A contact below Lead (e.g. subscriber) or with no lifecyclestage counts
toward names_captured (raw list membership) but not toward any of the 4
buckets - this is exactly why qual_rate in f_event_roi can be under 100%.

All credentials come from config.env (chmod 600, never web-served, never
in git). No em dashes anywhere.
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import requests

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- config ------
_ENV_PREFIXES = ("HUBSPOT_", "CAMPAIGN_", "SUPABASE_", "MKTG_")


def load_config(path=None):
    """Same resolution order as every other generator: config.env first,
    environment as the fallback. See generate_report.load_config."""
    path = path or os.path.join(HERE, "config.env")
    cfg = {}
    for k, v in os.environ.items():
        if k.startswith(_ENV_PREFIXES):
            cfg[k] = v
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    return cfg


CFG = {}
HS_TOKEN = None
HS = "https://api.hubapi.com"
HH = {}
SB_URL = ""
SB_KEY = ""
SCHEMA = "mktg"
_READY = False


def init(path=None):
    """Load config and populate module settings. Idempotent.

    Needs Supabase credentials as well as the HubSpot token, unlike the
    other 3 generators: fetch_event_roster() reads mktg.event directly (see
    module docstring)."""
    global CFG, HS_TOKEN, HH, SB_URL, SB_KEY, SCHEMA, _READY
    if _READY:
        return CFG
    CFG = load_config(path)
    HS_TOKEN = CFG.get("HUBSPOT_TOKEN") or ""
    if not HS_TOKEN:
        raise RuntimeError("HUBSPOT_TOKEN is not set. Put it in config.env next "
                           "to this script, or export it in the environment.")
    HH = {"Authorization": "Bearer " + HS_TOKEN, "Content-Type": "application/json"}
    SB_URL = (CFG.get("SUPABASE_URL") or "").rstrip("/")
    SB_KEY = CFG.get("SUPABASE_SERVICE_KEY") or ""
    SCHEMA = CFG.get("MKTG_SCHEMA", "mktg")
    _READY = True
    return CFG


# ------------------------------------------------------------- hubspot io -----
def hs_get(path, params=None):
    for attempt in range(5):
        r = requests.get(HS + path, headers=HH, params=params, timeout=60)
        if r.status_code == 429:
            time.sleep(1.5 * (attempt + 1)); continue
        r.raise_for_status()
        return r.json()
    raise RuntimeError("rate limited: GET " + path)


def hs_post(path, body):
    for attempt in range(5):
        r = requests.post(HS + path, headers=HH, json=body, timeout=60)
        if r.status_code == 429:
            time.sleep(1.5 * (attempt + 1)); continue
        r.raise_for_status()
        return r.json()
    raise RuntimeError("rate limited: POST " + path)


def pull_memberships(list_id):
    ids, after = [], None
    while True:
        params = {"limit": 250}
        if after:
            params["after"] = after
        r = hs_get("/crm/v3/lists/%s/memberships" % list_id, params)
        ids.extend(str(m["recordId"]) for m in r.get("results", []))
        after = (r.get("paging", {}).get("next") or {}).get("after")
        if not after:
            break
    return ids


def batch_read(obj, ids, properties):
    out = {}
    ids = [str(i) for i in ids]
    for i in range(0, len(ids), 100):
        chunk = ids[i:i + 100]
        r = hs_post("/crm/v3/objects/%s/batch/read" % obj,
                    {"properties": properties, "inputs": [{"id": x} for x in chunk]})
        for res in r.get("results", []):
            out[str(res["id"])] = res.get("properties", {})
        time.sleep(0.1)
    return out


# --------------------------------------------------------------- roster -------
def _sb_get(table, query):
    if not SB_URL or not SB_KEY:
        raise RuntimeError("SUPABASE_URL / SUPABASE_SERVICE_KEY are not set. "
                           "This script reads the event roster from mktg "
                           "directly - see the module docstring.")
    url = "%s/rest/v1/%s?%s" % (SB_URL, table, query)
    req = urllib.request.Request(url, headers={
        "apikey": SB_KEY,
        "Authorization": "Bearer " + SB_KEY,
        "Accept": "application/json",
        "Accept-Profile": SCHEMA,
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:400]
        raise RuntimeError("GET %s -> %s %s" % (url, e.code, detail))


def fetch_event_roster():
    """Read the hand-maintained roster straight from mktg.event /
    mktg.event_hubspot_list and join them in Python (two flat selects,
    rather than relying on PostgREST's nested-embed syntax). Returns a list
    of dicts with event_id, event_name, and hubspot_list_ids (a list, empty
    if the event has no HubSpot list attached yet). See the module
    docstring for why this script talks to Supabase at all, and for why an
    event can have more than one list."""
    events_rows = _sb_get("event", "select=event_id,event_name")
    list_rows = _sb_get("event_hubspot_list", "select=event_id,hubspot_list_id")

    ids_by_event = {}
    for r in list_rows:
        ids_by_event.setdefault(r["event_id"], []).append(r["hubspot_list_id"])

    roster = []
    for r in events_rows:
        roster.append({
            "event_id": r["event_id"],
            "event_name": r["event_name"],
            "hubspot_list_ids": ids_by_event.get(r["event_id"], []),
        })
    return roster


# ------------------------------------------------------- stage bucketing ------
STAGE_LEAD = "lead"
STAGE_MQL = "marketingqualifiedlead"
STAGE_SAL = "157687207"  # custom "Sales Accepted Lead" stage id, portal-specific
STAGE_SQL = "salesqualifiedlead"
STAGE_OPPORTUNITY = "opportunity"
STAGE_CUSTOMER = "customer"
STAGE_REPEAT_CUSTOMER = "1157693063"


def bucket_stage(stage):
    """Map a raw HubSpot lifecyclestage value to one of the 4 funnel
    buckets, or None if the contact is below Lead or unset. See the module
    docstring for the folding rules."""
    if stage == STAGE_LEAD:
        return "leads"
    if stage == STAGE_MQL:
        return "mqls"
    if stage in (STAGE_SAL, STAGE_SQL):
        return "sqls"
    if stage in (STAGE_OPPORTUNITY, STAGE_CUSTOMER, STAGE_REPEAT_CUSTOMER):
        return "opportunities"
    return None


# ----------------------------------------------------------------- compute ----
def build_dataset(roster=None):
    """One row of counts per event in the roster.

    roster, when passed, is the list already fetched by the caller (this is
    how sync_to_mktg.py drives it, since it already talks to Supabase for
    every other report). Each roster row's hubspot_list_ids may hold more
    than one list (see module docstring); this pulls every list for an
    event and takes the UNION of contact ids before bucketing, so a contact
    on two of an event's lists is not double-counted. Falls back to
    fetch_event_roster() so this module still runs standalone."""
    if roster is None:
        roster = fetch_event_roster()

    member_ids_by_event = {}
    for row in roster:
        eid = row["event_id"]
        list_ids = row.get("hubspot_list_ids") or []
        union = set()
        for list_id in list_ids:
            union.update(pull_memberships(list_id))
        member_ids_by_event[eid] = sorted(union)

    contacts_needed = set()
    for ids in member_ids_by_event.values():
        contacts_needed.update(ids)
    props = (batch_read("contacts", contacts_needed, ["lifecyclestage"])
             if contacts_needed else {})

    events = {}
    for row in roster:
        eid = row["event_id"]
        member_ids = member_ids_by_event.get(eid, [])
        counts = {"leads": 0, "mqls": 0, "sqls": 0, "opportunities": 0}
        for cid in member_ids:
            bucket = bucket_stage(props.get(cid, {}).get("lifecyclestage"))
            if bucket:
                counts[bucket] += 1
        events[eid] = {
            "names_captured": len(member_ids),
            "leads": counts["leads"],
            "mqls": counts["mqls"],
            "sqls": counts["sqls"],
            "opportunities": counts["opportunities"],
        }

    return dict(roster={r["event_id"]: r for r in roster}, events=events)


# ----------------------------------------------------------------- main ------
def main():
    """Standalone run: pull and print, write nothing. sync_to_mktg.py is the
    only thing that writes mktg.snap_event_funnel."""
    init()
    ds = build_dataset()
    if not ds["events"]:
        print("No rows in mktg.event yet - nothing to pull. Add at least one "
              "event (with a hubspot_list_id) first.")
        return
    print("%-24s %8s %8s %8s %8s %8s"
          % ("event", "names", "leads", "mqls", "sqls", "opps"))
    for eid, c in ds["events"].items():
        name = ds["roster"][eid].get("event_name", eid)
        print("%-24s %8d %8d %8d %8d %8d"
              % (name[:24], c["names_captured"], c["leads"], c["mqls"],
                 c["sqls"], c["opportunities"]))


if __name__ == "__main__":
    main()
