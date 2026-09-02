# Handoff - 2026-09-02

## Git state

Branch `main`, clean, pushed to
`github.com/marketing-team-msai/msai-marketing-reports`.

    4849833  Carry contact name and email through to snap_influence
    546ea59  Rename compute_deal_grain to compute_slide15_grain and say what it is
    d011e5a  Stop the netnew headline inheriting the overturned Amazon/Galco exclusion
    0fe5cea  Match the real mktg constraints: key, write order and array type
    02757e3  Make check-schema prove access, and keep the day row out of the report tally
    5f10f9f  Replace the workbook pipeline with a direct sync into the mktg schema

`4849833` added `contact_name` and `contact_email` to `snap_influence`. The
influence dataset already fetched firstname, lastname and email for every
influenced contact (the workbook showed it under Deal Contact Details); the
row builder was dropping it, leaving rows identifiable only by `contact_id`.
Both columns populate on all 359 rows, zero nulls. Email is now resolved once
per contact rather than once per campaign row, and `is_internal` reuses it.

## Verified and closed this session

**Pipeline replaced.** `sync_to_mktg.py` imports the pull and compute
functions from the three generators and writes entity-grain detail straight
into `mktg`. It never calls `build_workbook`, never touches Supabase Storage,
and does not import `run_all_reports.py` or `push_history.py`. Those two are
retired and no longer referenced by the workflow.

**Live row counts, verified by direct query, not by trusting run output:**

    snap_influence         359    228 distinct deals    $11,842,231.76
    snap_sourced_deal      861    $49,154,033.88 total
    snap_sourced_contact  4,296
    snap_lead_sla         7,213   72 over SLA
    run_log                  1    status=ok, reports_run=3, rows_written=12,729
    run_log_reports          3    all status=ok

**Even-split attribution proven exact.** `even_split_value` is the deal amount
over the size of the union of campaigns across all the deal's influenced
contacts, repeated per row, stored at full precision. Summed over distinct
(deal, campaign) it reproduces `compute_campaign_summary` to identical floats,
difference `0.0000000000`. Rounding per row previously drifted 7 cents across
337 pairs; the `round(share, 2)` was removed.

The repetition is real and load-bearing. Deal `60975075143` has four contacts
on one campaign, union size 1, so all four rows carry the full $50,000. A
naive `sum()` reports $200,000 of influence on a $50,000 deal. The view
collapses to one row per (deal, campaign) before summing.

**Amazon/Galco exclusion removed from the sourced headline.** The netnew
metrics cache was fed from `compute_deal_grain`, which reproduces slide 15 of
the July 2026 ELT offsite deck: Amazon dropped, Galco diverted. That rule was
overturned. It understated sourced pipeline by $4,389,498.59 across 10 deals
(7 Amazon at $363,949.59, 3 Galco at $4,025,549.00, one Galco deal being 92%
of the recovered value). Corrected to 148 / $9,237,904.98. The function is now
`compute_slide15_grain` with a docstring stating the exclusions and pointing
callers at `d["single_program"]`. `snap_sourced_deal` was never affected.

**SLA detail widened.** `detail_rows` covered only the 83 contacts inside the
lead-status loop; per-rep averages in the workbook were computed over the full
7,206-contact worked-pipeline population, which never became rows. Now 7,213
rows (7,206 stage population plus 7 portal-wide on Other/Advocate/Customer).
Per-rep totals check out against the last Excel run: Jake Parks 2,244 vs
~2,238, Steve Cunningham 1,742 vs ~1,737.

**Vertical corrected to contact properties.** `industry` and
`primary_subindustry_dropdown` live on the contact object, not the deal or
company. A deal takes the first non-null industry among its associated
contacts, else `Unknown`. 575 of 861 deals resolve; 263 have contacts with no
industry, 23 have no associated contacts at all.

**Workflow.** Runs `--check-schema` as a fail-fast gate then `sync_to_mktg.py`.
Cron passes no `--dry-run` (verified: `inputs.dry_run` is empty on a schedule
trigger and fails the `= "true"` test), so the daily job does a real write.
`contents: write` dropped to `contents: read`; the `prior_snapshot.json`
commit-back is gone.

**Population reconciliation.** The 861 vs 148 gap is definitional, not a bug.
861 is a row count of the full Net New window population; 148 is a metric
counting deals whose influenced contacts all fall in one program. The filter
is `is_single_program`, applied in the view, and reproduces the view exactly
by program. The 713 difference splits as 671 uninfluenced (null program,
$37,463,872.93, of which 389 are Amazon) and 42 multi-program ($2,452,255.97),
partitioning exactly with no residue.

## Open items

**(a) The `(multi)` and `(unclassified)` buckets in `v_sourced_by_program`.**
Both currently return 0 deals / $0.00 and are permanently unreachable: the
view filters `is_single_program = true`, which by construction excludes every
deal whose `program` is `(multi)` or null. They are dead rows in the output.
Decision needed: drop them from the view, or change the view so multi-program
deals are reachable. Note 42 genuinely marketing-influenced deals worth
$2,452,255.97 are currently invisible in every program-level total.

**(b) `write_day_log` merge.** Raised, explicitly deferred, NOT implemented.
Any `--only` run overwrites the whole-day `run_log` summary with just that
report's numbers. Hit during this session: a `--only influence` run left
`reports_run=1, rows_written=359`, corrected by re-running all three.

**(c) `snap_sourced_deal` rename.** Deferred. The name says sourced; the table
holds the full Net New population.

## Next task

1. `f_influence_by_campaign(include_amazon, campaign_type_filter)`, mirroring
   the shape of `f_sourced_by_program(include_amazon, close_year)`. It must
   collapse to one row per (deal, campaign) before summing `even_split_value`,
   or campaign totals will overstate. `campaign_type` is already a column on
   `snap_influence`, populated by `classify_campaign`.
2. The Lovable Pipeline Influence page on top of it.

## Things about this codebase that reading it will not tell you

**`--check-schema` compares column names and nothing else.** It passed clean
while the role had zero privileges on the schema, while `snap_lead_sla`'s
conflict target matched no constraint, and while `programs` was the wrong
type. Three real failures it cannot see. PostgREST serves its OpenAPI document
from the schema cache with no privilege required, so a clean column diff
proves only that the names line up. An access probe was added; keys and types
are still unchecked. Worth extending before the backfill is written, since
that will hit the same constraints from a different direction.

**Exposing a schema in Supabase Settings > API grants nothing.** It adds the
schema to PostgREST's search path. Postgres privileges are separate, and a
schema created via raw SQL does not get the grants a dashboard-created one
does. Symptom is `42501 permission denied for schema mktg` on every call while
the key works fine against `public`.

**Every `snap_*` table and `run_log_reports` has a foreign key to
`run_log.snapshot_date`.** The day row must exist before anything else can be
written. `open_day_log` creates it as `running` before the first report;
`write_day_log` rewrites it at the end.

**`pair_rows` in `generate_report.py` is `(deal_id, contact_id)` 2-tuples.**
Not triples, no campaign, no value. The even-split share exists only inside
`compute_campaign_summary`. The triple grain in `snap_influence` is built by
expanding pair_rows against `contact_campaigns`.

**Dead code that looks live.** `prior` in `generate_report.main()` is loaded
from `prior_snapshot.json` and never read - only the write-back at the end is
live. `dg_sourced` and `dg_share` in `generate_netnew_report.main()` are
assigned and never read anywhere.

**The SLA report needs a fifth HubSpot scope, `crm.objects.owners.read`.**
Its first call is `GET /crm/v3/owners`. Without it that one report 403s
immediately while the other two succeed, which reads like a bad token rather
than a missing scope. `fetch_owners()` is reused by the netnew sync for
`owner_name`.

**Config is lazy now.** All three generators populate module settings in
`init()` rather than at import time, so importing a generator for its compute
functions costs nothing and needs no token. `config.env` still wins over the
environment; the workflow writes it from secrets at run time and deletes it
after.

**Data gaps that are not code faults.** `primary_subindustry_dropdown` is set
on only 38 of 557 fetched contacts, so 819 of 861 deals carry
`sub_vertical = 'Unknown'`. 1,065 of 7,213 SLA rows have no
`hs_v2_date_entered_current_stage`, so `days_in_lifecycle_stage` and
`days_since_last_change` are null there and will be excluded from averages
rather than counted as zero. 21 contacts have no name, 16 no email.

**`is_internal` does no work on `snap_influence`.** Zero of 359 rows are
`@multisensorai.com` across 128 distinct email domains. It fires correctly on
`snap_sourced_contact` (18 rows). Not a bug, but do not build a filter
expecting it to select anything on the influence table.

**Windsor is no longer pulled.** The sync does not call `pull_windsor`, and
`WINDSOR_*` was dropped from the workflow's `config.env`. Ad-source data is
the separate, still-open `snap_ad_source` task.

**`is_seeded` is always false here.** This script is the live daily sync. Only
the separate historical-backfill process writes `true`. That logic is
deliberately not in this script.

**`snap_influence` is portal-wide by design.** `pull_deals()` filters only on
`createdate >= anchor`, with no pipeline filter, while `snap_sourced_deal` is
Net New only. The two tables are intentionally not cross-drillable by
`deal_id`; they answer different questions.
