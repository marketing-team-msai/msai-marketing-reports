# MSAI Marketing Reports

Three HubSpot reports synced daily into the `mktg` schema in Supabase by
`sync_to_mktg.py`. The `snap_*` tables hold entity-grain detail; the views and
functions own all aggregation.

## Ratified rules

- `is_single_program` is false for uninfluenced (null program) and
  multi-program deals. All sourced-pipeline metrics currently exclude both.
  This governs the headline number and was previously undocumented.
- The contacts-by-stage funnel is COUNTS ONLY. Ratified 2026-09-02.
  `snap_sourced_contact.influenced_value` was removed rather than fixed.
  It held the full amount of every Net New deal a contact touched, so two
  contacts on one deal each carried the whole deal and `sum()` across
  contacts double counted: 12 deals, $1,129,524.90, none Amazon or Galco.
  The ETL comment said de-duplication was "the view's job"; the view never
  did it and could not, because the table has no `deal_id`.
  An even-split dollar column was considered and rejected: it fixes the
  number while keeping the shape that caused it. Do not add one back.
  The funnel answers "where do marketing-sourced contacts sit", a count
  question, and is captioned directional-only anyway because HubSpot
  auto-advances and skips stages. Dollars stay at deal grain, on Overview
  and Influence, where the dedupe is proven exact to the cent.

## Gotchas

- `f_sourced_by_program` is program-grain and returns 5 rows, not 148.
  Four `row_type = 'program'` rows plus one `row_type = 'reconciling'` row
  for multi-program deals. The headline is
  `sum(sourced_pipeline) where row_type = 'program'` = 148 / $9,237,904.98.
  Summing all five rows gives $11,690,160.95 and is wrong. `f_pipeline_model`
  and the /overview tile and chart all filter on `row_type`; anything new
  that reads this function must too. There is no `amount_home` column.
  `v_sourced_by_program` is `select * from f_sourced_by_program(true, null)`,
  deliberately one body so the two cannot drift.
- `measurement` is `not_measured` for any program listed in the
  `unmeasured_programs` row of `config_settings`, currently Advertising.
  That zero means "not captured", not "captured and zero", and renders as a
  dash. Delete the config row when `snap_ad_source` is built. PR & Brand's
  zero is genuine and renders as $0.00.
- `snap_sourced_deal` holds the FULL Net New population (861 rows), not only
  sourced deals. The 148 metric is `where is_single_program = true`, applied
  in the view, not the ETL. Table name is misleading; rename is deferred.
- `snap_influence` has two dollar columns at row grain. Naive
  `sum(amount_home)` across rows gives $39.2M because deal amount repeats per
  contact x campaign row. Always dedupe explicitly.
- `create or replace function` does not replace a function when the argument
  signature changes. It creates a second overload and Postgres throws
  "could not choose the best candidate function." Always
  `drop function if exists` the old signature first.
- Any `--only` run overwrites the whole-day `run_log` summary.
- `docs/schema.sql` is a GENERATED dump of every `mktg` view and function.
  Read it instead of asking for the DDL to be run by hand. It is not applied
  by anything, so it goes stale silently: refresh it whenever a migration
  lands. The regeneration query is in its header.

## Population reconciliation (snapshot 2026-09-02)

snap_sourced_deal: 861 deals / $49,154,033.88 total, splitting as

    single-program (the 148 metric): 148 / $9,237,904.98
    uninfluenced (null program):     671 / $37,463,872.93  [389 are Amazon]
    multi-program:                    42 / $2,452,255.97

snap_influence: 359 rows / 228 distinct deals / $11,842,231.76
snap_sourced_contact: 4,297 | snap_lead_sla: 7,213 | over SLA: 72

snap_sourced_contact was recorded as 4,296. Re-counted live: 4,297 rows,
4,297 distinct contact_id.

## Ad source / Windsor

Windsor is NOT decommissioned, and it is NOT wired into the mktg pipeline.
Both halves matter:

- `pull_windsor()` still exists in `generate_report.py` and is still called by
  that script's standalone workbook run. The code path is live.
- `sync_to_mktg.py` never calls it and never writes `snap_ad_source`. The
  workflow's generated `config.env` carries no `WINDSOR_*`, so a scheduled run
  has no key and pulls nothing.
- `config.env.example` still documents `WINDSOR_API_KEY` and
  `WINDSOR_DATE_PRESET`, and a local `config.env` may still carry the key.
- `mktg.snap_ad_source` and `mktg.v_ad_performance` exist and hold 0 rows.

So the accurate status is: the ETL leg is unbuilt, not retired. Do not write
"Windsor is no longer pulled" - it reads as decommissioned and it is not.
README.md still describes the pipeline as HubSpot plus Windsor, which is true
of `generate_report.py` and false of the daily sync.

Paid attribution has a path, but only through the unbuilt `snap_ad_source`
leg. Nothing in the Campaign Influence lists carries it.

## Open items

- Every logged-in employee can read all of `mktg` directly. `authenticated`
  holds SELECT on all 12 tables and all 8 views, and the `/auth` gate
  auto-confirms any `@multisensorai.com` address. Not for fixing now, but
  it is a wider read surface than anyone specified.
- The actual read path is undocumented. `SETUP.md:430` describes an anon
  key plus a read-only policy for named views. What is deployed is the
  publishable key plus a signed-in user's JWT, so PostgREST runs as
  `authenticated` and reads whatever that role is granted. `anon` holds no
  grants at all, so the documented setup would see nothing.

## Working agreement

Stop and ask before changing any definition, grain, or inclusion/exclusion
rule. Proceed without asking on mechanical fixes needed to make
already-approved logic run: wrong conflict key, missing grant, wrong column
type. Report row counts alongside distinct-entity counts and dollar sums;
row count alone does not prove grain held.
