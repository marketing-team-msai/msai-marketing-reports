# MSAI Marketing Reports

Three HubSpot reports synced daily into the `mktg` schema in Supabase by
`sync_to_mktg.py`. The `snap_*` tables hold entity-grain detail; the views and
functions own all aggregation.

## Ratified rules

- `is_single_program` is false for uninfluenced (null program) and
  multi-program deals. All sourced-pipeline metrics currently exclude both.
  This governs the headline number and was previously undocumented.

## Gotchas

- `v_sourced_by_program` is program-grain. `count(*)` returns 4, not 148.
  Deal count is `sum(sourced_deals)`. There is no `amount_home` column.
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

## Population reconciliation (snapshot 2026-09-02)

snap_sourced_deal: 861 deals / $49,154,033.88 total, splitting as

    single-program (the 148 metric): 148 / $9,237,904.98
    uninfluenced (null program):     671 / $37,463,872.93  [389 are Amazon]
    multi-program:                    42 / $2,452,255.97

snap_influence: 359 rows / 228 distinct deals / $11,842,231.76
snap_sourced_contact: 4,296 | snap_lead_sla: 7,213 | over SLA: 72

## Working agreement

Stop and ask before changing any definition, grain, or inclusion/exclusion
rule. Proceed without asking on mechanical fixes needed to make
already-approved logic run: wrong conflict key, missing grant, wrong column
type. Report row counts alongside distinct-entity counts and dollar sums;
row count alone does not prove grain held.
