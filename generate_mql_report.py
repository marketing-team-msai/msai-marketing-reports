#!/usr/bin/env python3
"""Marketing Qualified Leads (MQLs) generated per quarter - the HubSpot pull.

No workbook. sync_to_mktg.py imports this and writes mktg.snap_mql_entry;
mktg.f_mql_by_quarter() does the counting. Read-only against HubSpot.

DEFINITION (Alecia, 2026-10-04)
    A contact is an MQL generated in quarter Q when its Lead Status
    (hs_lead_status) ENTERED "Awaiting Sales Qualification" - or
    "Awaiting Sales Qualification - Returning", stored as the value
    'Returning Customer' - during Q, and its Lead Status TODAY is not
    Junk or Disqualified. Counted once per contact per quarter; a contact
    that enters again in a later quarter counts again there.

    "Entered" is read from the hs_lead_status PROPERTY HISTORY: an entry
    is a history row carrying one of ENTRY_STATUSES whose previous row did
    not. Same source as generate_sla_report.entered_status(), for the same
    reasons stated there.

FIELDS CONSIDERED AND NOT USED FOR THE FACTS
    previous_lead_status (custom) holds display LABELS, not values, and on
    2026-10-04 disagreed with the real history on 49,240 of 49,505
    contacts - most often it holds the CURRENT status. Even when right it
    only reaches back one step, so ASQ -> In Progress -> Nurture would be
    invisible. Not used.

    lead_status___last_updated_date (custom) IS reliable enough to NARROW
    which contacts to re-read: on 2026-10-04 it caught 363 of 363 contacts
    that entered ASQ since 2026-09-01, and 99.4% of all status changes
    landed on the same day or the day before. It decides only who gets
    their history read; the history decides everything else.

INCREMENTAL PULL
    Each run reads history for (a) every contact already in the previous
    snapshot, to refresh their current status, and (b) every contact whose
    lead_status___last_updated_date is on or after LOOKBACK_DAYS before
    the previous snapshot, plus (c) every contact sitting in an entry
    status right now as a belt-and-braces net for a missed date stamp.
    A typical day is ~35 status changes, so one or two batch calls. With
    no previous snapshot, or with full=True, every contact is read
    (~1,000 calls, 15-20 minutes) - the workflow does that weekly.

EXCLUSIONS
    MQL_EXCLUSIONS is the single source. Each matching entry is still
    written, tagged with exclusion_reason, so the count can be audited
    and an exclusion reversed without a re-pull. Ratified by Alecia
    2026-10-04.
"""
import json
import time

import generate_sla_report as sla

ENTRY_STATUSES = ("Awaiting Sales Qualification", "Returning Customer")

# Windows are UTC instants covering the US Central calendar day (CDT,
# UTC-5) - written out so no timezone database is needed to apply them.
MQL_EXCLUSIONS = [
    {
        # A HubSpot workflow set ~5,800 List Vendor contacts to Awaiting
        # Sales Qualification at 8am Central; a PROPERTY_RESTORE at 5pm
        # undid part of it. Every entry that day came from one of those two
        # sources. Left in, it adds ~4,640 to Q2 2026.
        "reason": "workflow_misfire_2026_05_25",
        "start": "2026-05-25T05:00:00Z",
        "end": "2026-05-26T05:00:00Z",
        "source_types": ("AUTOMATION_PLATFORM", "PROPERTY_RESTORE"),
        "previous_status": None,
    },
    {
        # One automated batch moved 122 Nurture contacts into Awaiting Sales
        # Qualification at 4pm Central; most went straight back to Nurture.
        # Recycled leads, not newly generated ones. The 11 manual (CRM_UI)
        # entries the same day are NOT excluded.
        "reason": "nurture_recycle_batch_2026_09_21",
        "start": "2026-09-21T05:00:00Z",
        "end": "2026-09-22T05:00:00Z",
        "source_types": ("AUTOMATION_PLATFORM",),
        "previous_status": "Nurture",
    },
]

LOOKBACK_DAYS = 3
HISTORY_CHUNK = 50
SEARCH_CAP = 9900  # HubSpot search stops paging at 10,000 results

CONTACT_PROPS = ["hs_lead_status", "email", "lead_source", "createdate",
                 "firstname", "lastname", "company", "hubspot_owner_id"]


def init():
    sla.init(make_outdir=False)


def exclusion_reason(entered_at, source_type, previous_status):
    for x in MQL_EXCLUSIONS:
        if not (x["start"] <= entered_at < x["end"]):
            continue
        if source_type not in x["source_types"]:
            continue
        if x["previous_status"] is not None and previous_status != x["previous_status"]:
            continue
        return x["reason"]
    return None


def _norm_ts(ts):
    """HubSpot history timestamps are ISO UTC with 'Z'. Normalise to a fixed
    width so plain string comparison against MQL_EXCLUSIONS is exact."""
    return ts[:19] + "Z" if ts and ts.endswith("Z") else ts


def entries_from_history(history):
    """Every entry into an ENTRY_STATUSES value, oldest first.

    history is HubSpot's propertiesWithHistory list, newest first. Moving
    between the two entry statuses is not a new entry."""
    h = list(reversed(history or []))
    out = []
    for i, e in enumerate(h):
        v = e.get("value")
        if v not in ENTRY_STATUSES:
            continue
        prev = h[i - 1].get("value") if i > 0 else None
        if prev in ENTRY_STATUSES:
            continue
        ts = _norm_ts(e.get("timestamp"))
        src = e.get("sourceType")
        out.append({
            "entered_at": ts,
            "entered_status": v,
            "previous_status": prev or None,
            "source_type": src,
            "exclusion_reason": exclusion_reason(ts, src, prev),
        })
    return out


# ------------------------------------------------------------- hubspot -------
def _search_ids(filters, lo=None, hi=None):
    """Contact ids matching filters, splitting on lead_status___last_updated_date
    whenever a slice would hit the search cap."""
    f = list(filters)
    if lo is not None:
        f.append({"propertyName": "lead_status___last_updated_date", "operator": "GTE", "value": str(lo)})
    if hi is not None:
        f.append({"propertyName": "lead_status___last_updated_date", "operator": "LT", "value": str(hi)})
    payload = {"filterGroups": [{"filters": f}], "properties": ["hs_object_id"],
               "limit": 100, "sorts": [{"propertyName": "hs_object_id", "direction": "ASCENDING"}]}
    first = sla._req("POST", "/crm/v3/objects/contacts/search", payload)
    if first.get("total", 0) > SEARCH_CAP and lo is not None:
        hi_ = hi if hi is not None else int(time.time() * 1000) + 86400000
        mid = (lo + hi_) // 2
        if mid > lo:
            return _search_ids(filters, lo, mid) | _search_ids(filters, mid, hi_)
    ids, r = set(), first
    while True:
        ids.update(x["id"] for x in r.get("results", []))
        nxt = (r.get("paging") or {}).get("next")
        if not nxt:
            return ids
        payload["after"] = nxt["after"]
        r = sla._req("POST", "/crm/v3/objects/contacts/search", payload)


def changed_since(since_ms):
    """Contacts whose lead status was stamped as changed on or after since_ms."""
    return _search_ids([], lo=since_ms)


def in_entry_status_now():
    return _search_ids([{"propertyName": "hs_lead_status", "operator": "IN",
                         "values": list(ENTRY_STATUSES)}])


def read_with_history(ids):
    """{id: (properties, hs_lead_status history)} for ids, 50 per call."""
    ids = sorted(ids, key=int)
    out = {}
    for i in range(0, len(ids), HISTORY_CHUNK):
        payload = {"inputs": [{"id": x} for x in ids[i:i + HISTORY_CHUNK]],
                   "properties": CONTACT_PROPS,
                   "propertiesWithHistory": ["hs_lead_status"]}
        r = sla._req("POST", "/crm/v3/objects/contacts/batch/read", payload)
        for res in r.get("results", []):
            out[res["id"]] = (res.get("properties", {}),
                              res.get("propertiesWithHistory", {}).get("hs_lead_status", []))
    return out


def read_all_with_history():
    """Every contact in the portal, via the list endpoint (50 per page)."""
    out, after = {}, None
    while True:
        params = {"limit": HISTORY_CHUNK, "properties": ",".join(CONTACT_PROPS),
                  "propertiesWithHistory": "hs_lead_status", "archived": "false"}
        if after:
            params["after"] = after
        r = sla._req("GET", "/crm/v3/objects/contacts", params=params)
        for res in r.get("results", []):
            out[res["id"]] = (res.get("properties", {}),
                              res.get("propertiesWithHistory", {}).get("hs_lead_status", []))
        nxt = (r.get("paging") or {}).get("next")
        if not nxt:
            return out
        after = nxt["after"]


def build_dataset(known_ids=None, since_ms=None, full=False):
    """Pull and return {"contacts": {id: {"props", "entries"}}, "mode", "read"}.

    known_ids: contact ids in the previous snapshot. since_ms: epoch ms to
    search lead_status___last_updated_date from. Either missing, or
    full=True, means a full portal read."""
    if full or known_ids is None or since_ms is None:
        mode = "full"
        raw = read_all_with_history()
    else:
        mode = "incremental"
        ids = set(known_ids) | changed_since(since_ms) | in_entry_status_now()
        raw = read_with_history(ids)
    contacts = {}
    for cid, (props, hist) in raw.items():
        entries = entries_from_history(hist)
        if entries:
            contacts[cid] = {"props": props, "entries": entries}
    return {"contacts": contacts, "mode": mode, "read": len(raw)}


if __name__ == "__main__":
    init()
    ds = build_dataset(full=True)
    print(json.dumps({"mode": ds["mode"], "read": ds["read"],
                      "contacts_with_entries": len(ds["contacts"])}))
