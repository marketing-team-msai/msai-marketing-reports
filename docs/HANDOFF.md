# Handoff - 2026-09-14

Supersedes the 2026-09-02 handoff. That session built the pipeline; this one
audited it after twelve days of unattended running, found three real problems,
and added deal-level detail to the dashboard.

## Git state

Branch `main`, clean, pushed to
`github.com/marketing-team-msai/msai-marketing-reports`.

    d2cac52  Qualified lead SLA moves from 14 to 30 days
    4fb5e2f  Move the Net New window anchor to 2026-01-01 so the labels are true
    e0532b2  Refresh CLAUDE.md to the 2026-09-14 snapshot and document the snapshot trap

Earlier work by Alecia between the two sessions: `38f9a8a` through `5a6559e`,
covering `f_influence_by_campaign`, the `row_type` migration, the counts-only
funnel, `docs/schema.sql` and the Windsor status correction. All four staged
migrations are applied, despite two of those commit messages saying
"unapplied" - that wording is stale, not a warning.

The dashboard lives in Lovable (`msa-dash-pro`,
`407f78f9-8bc0-4299-843b-34a3d274f53e`), not in this repo.

## Live state, verified 2026-09-14

    snap_influence         291 rows / 136 deals / $9,603,916.76
    snap_sourced_deal      436 rows / $33,755,615.79
                             sourced (single-program)  71 / $6,602,745.04
                             uninfluenced             322 / $24,221,822.71
                             multi-program             43 / $2,931,048.04
    snap_sourced_contact  4,143 rows
    snap_lead_sla         7,230 rows, 55 over SLA
                             Qualified 48, In Progress 6, Awaiting 1
    run_log               status ok, 3 reports, 0 failed, 12,100 rows

    window_anchor_netnew   2026-01-01
    SLA thresholds         In Progress 14, Qualified 30, Awaiting 1

The sync has now run every day since 2026-09-02 with `status=ok` and zero
failed reports.

## What this session found and fixed

### 1. A dated silent failure, 23 days out

Every `f_*` function returns rows for EVERY snapshot_date. With one snapshot
that was invisible; with thirteen it was 356 rows on
`f_influence_by_campaign`, growing about 27 a day. PostgREST caps every
response at 1000 rows and the functions order oldest-snapshot-first, so the
NEWEST snapshot would have been the first thing truncated, around
**2026-10-07**. The dashboard filtered client-side, so it would have started
rendering empty pages with no error while the freshness banner still read
today's date.

Fixed in the dashboard by pushing the filter server-side
(`.rpc(fn, args).eq("snapshot_date", d)`). Verified identical numbers before
and after on all five functions. The `f_influence_by_campaign` payload went
from 356 rows to 30 and is now flat regardless of how many snapshots
accumulate. No migration was needed: PostgREST filters set-returning
functions server-side, which is worth knowing before anyone writes DDL to
solve this class of problem.

`fetchInfluenceDeals` also now pages through `snap_influence` in 1000-row
batches with a stable `deal_id` sort, each page building its own query,
because an awaited PostgREST builder cannot be re-run.

`src/lib/sla.ts` was already safe: `.order(snapshot_date desc).limit(100)`
always keeps the newest snapshot in the payload. That is the correct version
of the pattern the other files had wrong.

### 2. The window anchor was a lie

`config_settings.window_anchor_netnew` said 2026-01-01, which is what the
dashboard displayed. `DEALS_CREATED_SINCE` said 2025-06-01, which is what the
ETL pulled. **431 of 866 Net New deals, half the table, predated the window
every caption claimed.**

Alecia chose to move the ETL to 2026-01-01. Done in all five places that
carry the anchor: the workflow, `config.env.example`, the module defaults in
both generators, and `config_settings`, which already agreed. The module
defaults mattered: a local run with no `DEALS_CREATED_SINCE` in `config.env`
was silently falling back to 2025-06-01.

The figures moved a long way. Neither set was bad arithmetic; they answer
different questions:

    sourced pipeline     145 / $8,840,403.98   ->  71 / $6,602,745.04   -25%
    influenced pipeline  231 / $12,046,458.76  -> 136 / $9,603,916.76   -20%
    Net New population   866 / $44,914,165.00  -> 436 / $33,755,615.79

The sync upserts and never deletes, so narrowing the window left 845 rows
from the earlier wider run sitting in the 2026-09-14 snapshot. Alecia ran
`docs/migrations/2026-09-14_window_anchor_2026_cleanup.sql`, which removed
them; verified afterwards at 436 / 291 / 4143 with earliest create dates
inside the window. **Snapshots 2026-09-02 to 2026-09-13 still hold the wider
population.** Any trend across that boundary shows a step down that is a
definition change, not a business event. The optional block in that migration
file cleans them if you decide the comparable series matters more than the
historical record.

### 3. Qualified SLA moved to 30 days

Changed in the same four-places-plus-config-table pattern as the anchor,
because the ETL and the dashboard read different sources for this number too.
Breaches fell 53 to 48, total over SLA 60 to 55.

The small movement is the finding. Only 5 Qualified contacts sat between 14
and 30 days. Of the 55 Qualified, 14 are 30-90 days old and **34 are over 90**,
median 171 days, oldest 1,609. Relaxing the threshold clears the handful near
the boundary and leaves 48 stale by any definition.

## Dashboard changes

New section on Net New / Sourced, "Deals and the campaigns that sourced them":
a five-way filter (Influenced 114 by default, Sourced only 71, Multi-program
43, Uninfluenced 322, All 436), search across deal, company, owner, contact
and campaign, and expandable rows showing each contact, their email, and chips
for every campaign that touched them. Uninfluenced deals expand to one line
explaining why there is nothing there rather than an empty list.

The "Sourced only" filter totals $6,602,745.04, matching the Sourced Pipeline
KPI exactly, so the headline drills into the deals behind it and ties out.
Verified: zero uninfluenced deals carrying contacts, zero influenced deals
missing them.

This works because `snap_influence` and `snap_sourced_deal` join cleanly on
`(snapshot_date, deal_id)`. All 71 sourced and all 43 multi-program deals
appear in both; the 322 uninfluenced appear in neither, which is the correct
answer to "which campaigns touched this deal". Their TOTALS remain
incomparable - portal-wide versus Net New - and the section is captioned to
say amounts are full deal values, not even-split shares.

Also: the window anchor now reads in plain body text on all three pages rather
than as grey micro-copy, sourced live from `config_settings` and never
hard-coded; Overview carries an extra note that Sourced is Net New only while
Influenced is portal-wide; the Pipeline Influence drilldown keeps its
2027-close default (Alecia's decision) but now says so, since it shows 23 of
136 deals; the header dropped its "· Page" suffix; the active nav link is
shaded with `bg-secondary`; and Overview was switched from its own inline
header to the shared `DashboardHeader`, which it needed because it previously
had no navigation at all.

## Open items

**(a) `snap_ad_source` and `v_ad_performance` hold 0 rows.** The Windsor leg
is unbuilt, not retired. `pull_windsor()` still exists and still runs in
`generate_report.py`'s standalone workbook path; the daily sync never calls
it and the workflow's `config.env` carries no `WINDSOR_*`. Advertising shows
`measurement = not_measured` for this reason.

**(b) `snap_close_rate` is superseded, decided 2026-09-14.** It was neither
unbuilt nor orphaned. Its columns are `segment_type / segment_value /
won_count / lost_count / close_rate`, and `generate_netnew_report.py:115`
hard-codes `close_rate_amazon 0.70` and `close_rate_non_amazon 0.30` inside
`MODEL`, lifted from the July 2026 ELT offsite deck. The table was the
unbuilt home for measured versions of those constants.

It is now replaced by `f_close_rate` + `v_close_rate`, staged in
`docs/migrations/2026-09-14_f_close_rate.sql` and NOT YET APPLIED. A
function, not an ETL leg, because the table was segment-grain - an aggregate
in a `snap_` table, against the rule `sync_to_mktg.py` states in its own
docstring - and every input was already in `snap_sourced_deal` at deal
grain. So: no new pull, no daily write, cannot drift from the deal data, and
it backfills every snapshot already written the moment it lands.

The table is KEPT and documented as superseded. Dropping it is a separate
call; the down migration does not touch it.

**What the population actually is.** Verified live before writing anything,
because the labelling depends on it:

- NOT all won and lost opportunities. The ETL filters pipeline EQ
  813739955, so all 436 rows carry `pipeline = 'Net New Pipeline'`. Other
  pipelines are absent entirely.
- NOT marketing-sourced only, which is the likelier misread given the table
  name. 322 of 436 are uninfluenced, 71 single-program, 43 multi-program.
  The denominator is every deal in the pipeline, so these are commercial
  rates, not marketing rates. Do not caption them "marketing sourced".
- Closed splits exactly: 272 = 205 Closed Won + 67 Closed Lost, no third
  terminal stage, no null `is_closed_won`. Nothing leaks out of the
  denominator.
- It is a CREATE-date cohort, not a close-date window, so it is not
  comparable to the offsite 0.70 / 0.30 which came from a wider book
  (425 won / $8.52M against 205 won / $5.89M here).

**Both rates are returned and separately labelled**, because they diverge:

    segment      deal_win_rate   dollar_win_rate
    All Net New         0.7537            0.6255
    Amazon              0.9568            0.7186
    non-Amazon          0.4545            0.4358
    Dist & Whse         0.9290            0.6890

Amazon wins nearly every deal and loses the larger ones. Its dollar rate,
0.7186, lands almost exactly on the offsite's 0.70 while its deal rate is
0.96 - the best available evidence that the offsite constant was
dollar-weighted. non-Amazon is above its 0.30 on either basis. Neither is
proof, given the population mismatch.

Segments are `all` + `amazon` + `vertical`, Alecia's call. Only two
verticals clear the floor: Distribution & Warehousing (169) and Unknown
(70). The other 13 are n<=11 and come back `below_threshold` with null rates
and populated counts. Program was rejected as a segment: Content &
Technology 49, `(multi)` 5, Events 2.

Logic verified before staging, since the migration cannot be run from here:
the function body was transliterated to SQLite and run over the real 436
rows, diffed against expectations derived independently in plain Python.
18/18 rows exact, `won + lost = closed` on every row, all three segment
types totalling 272 / 205 / $5,886,665.20, `close_year=2026` returning the
same 272 / 205 and `close_year=2025` returning nothing. PASTE 2 in the
migration re-asserts all of that against live Postgres.

`docs/schema.sql` still needs regenerating once this is applied. It is a
generated dump and was deliberately not hand-edited.

**(c) `write_day_log` merge, still deliberately not implemented.** Any
`--only` run overwrites the whole-day `run_log` summary with just that
report's numbers. Hit twice now. Re-running all three is the workaround.

**(d) `snap_sourced_deal` rename, deferred.** The name says sourced; the
table holds the full Net New population.

**(e) The `(multi)` bucket, settled 2026-09-14.** Staged in
`docs/migrations/2026-09-14_influenced_pipeline_by_program.sql`, NOT YET
APPLIED.

The data reframed the question. Every multi-program deal touches exactly TWO
programs: 41 are Content & Technology + Events ($2,907,483.04), 2 are
Content & Technology + PR & Brand ($23,565.00). Across all 114 influenced
Net New deals, Content is present on 97%, Events 39%, PR & Brand 2%,
Advertising 0%.

So the single-program rule was not mis-attributing evenly. It was hiding
Events specifically. Events touches 44 deals worth $3,109,583.04, of which
only 3 worth $202,100.00 appeared in any program total, because Events
almost never occurs without Content and Content is on nearly everything.
94% of Events-touched pipeline was invisible.

Alecia's decision: count each deal once in the headline, show participation
per program without splitting dollars, and make the overlap explicit. No
re-attribution, no new sourcing model, and Events is NOT promoted to source
just because Content is common. Four new objects:

    f_influenced_pipeline        each deal ONCE. row_type total /
                                 single_program / multi_program
    f_influenced_by_program      full deal value to every program that
                                 touched it. NOT ADDITIVE
    f_influenced_by_combination  mutually exclusive, reconciles exactly
    v_influenced_deal_detail     drill-through, deal x contact x campaign
    v_deal_program               the dedupe grain under all of it

Reconciliation, verified live rather than hard-coded:

    single-program    71 deals   $6,602,745.04
    multi-program     43 deals   $2,931,048.04
    total            114 deals   $9,533,793.08
    ex-Amazon        107 deals   $9,169,843.49

Participation, which does NOT sum: Content 111 / $9,331,693.08, Events 44 /
$3,109,583.04, PR & Brand 2 / $23,565.00, Advertising 0 / not_measured. Rows
total $12,464,841.12 against a true $9,533,793.08, so any overall figure has
to come from `f_influenced_pipeline`.

The dedupe is load-bearing. Naive summing over `snap_influence` rows gives
$39,354,872.17; deduped at deal x program it is $12,464,841.12; unique deals
$9,533,793.08. 61 of the 157 (deal, program) pairs are backed by more than
one row.

**Terminology.** The single-program rule identifies single-program
INFLUENCE, not opportunity origin, and is now labelled "Single-program
influenced pipeline". The workbook labels in `generate_netnew_report.py`
were changed - 14 display strings, no calculation, no dict key, no column
name. `f_sourced_by_program`'s columns were deliberately NOT renamed because
the Lovable dashboard reads `sourced_deals` and `sourced_pipeline` by name.
**The label change still has to be applied in `msa-dash-pro`**; this repo
cannot do it. Labels are in `config_settings` so the dashboard reads them
live.

**Even split untouched.** `even_split_value` and `f_influence_by_campaign`
keep their exact behaviour, relabelled "Allocated influenced pipeline - even
split". Equal splitting is deliberately not used for participation.

**Scope.** The new objects are Net New only; `snap_influence` is
portal-wide, and 22 of its 136 deals are dropped. Their totals will not
match `f_influence_by_campaign` and that is correct.

**Two sources of truth, flagged not fixed.** `config_program_keywords` is
the SQL mirror of `classify_program()`. Verified identical on 2026-09-14 -
11/18/6 keywords, same eval order, zero disagreements across all 29 campaign
names - and it will drift. Query 2.8 in the migration is the alarm.

Logic verified before staging, since the migration cannot be run from here:
each body transliterated to SQLite, run over the real rows, diffed against
expectations derived independently in Python. All three functions matched on
both Amazon toggles, combinations reconciled to the headline in deals and
dollars, and the two properties the spec named were tested by injecting
synthetic rows - an extra contact, and an extra campaign, inside a program a
deal already had. Neither moved any program's dollars.

**(f) No retention policy.** `snap_lead_sla` is 93,937 rows across all
snapshots and grows about 7,200 a day. Nothing prunes.

**(g) No failure alerting.** The workflow has no notification step. If the
sync starts failing the only signal is the dashboard banner, which someone
has to look at.

**(h) `--check-schema` compares keys and types too, as of 2026-09-14.**
It used to compare column names and nothing else, and passed clean through
four real failures: zero privileges on the schema, a conflict target matching
no constraint, a wrong column type, and the 1000-row cap. The first was
already covered by the access probe. Two of the remaining three are now
covered:

- `ON_CONFLICT` against the primary key the spec advertises
- foreign keys, including a flag if a table we write has no `run_log` parent,
  which is the day-row ordering contract
- NOT NULL columns we never send, and NOT NULL columns we send null to
- column types, `format` from the spec against the values `_fixture_rows()`
  actually builds, with date and timestamp strings parsed rather than only
  type-tested

All of it comes out of the OpenAPI spec the check was already fetching, so
there is no extra request and no DDL. The workflow runs it before the HubSpot
pull, so the daily run now fails fast on any of these.

Verified by breaking one thing at a time - stale conflict column, missing
conflict target, float into integer, bool into integer, `""` and
`"(no history)"` into date, str into numeric, str into boolean, scalar into
`text[]`, non-ISO timestamp, null into NOT NULL, dropped NOT NULL column,
nonexistent column. 14 of 14 caught, each with a nonzero exit. That harness
is not in the repo; it needs live credentials and there is no test runner
here. Say the word and it can be.

Still uncovered: the 1000-row cap, which is a read-path property rather than
a schema one, and orphan rows.

**(i) Every logged-in employee can read all of `mktg` directly.**
`authenticated` holds SELECT on all tables and views and the `/auth` gate
auto-confirms any `@multisensorai.com` address. Wider than anyone specified.

## Things about this system that reading it will not tell you

**Two sources of truth is the recurring bug in this project.** The window
anchor and the SLA thresholds both live in a config table the dashboard reads
AND in environment values the ETL reads. Both diverged. When changing any
number of this kind, change every place at once and check the DB table too.

**Exposing a schema in Supabase Settings > API grants no privileges.** It adds
the schema to PostgREST's search path. Postgres grants are separate, and a
schema created via raw SQL does not get the grants a dashboard-created one
does. Symptom: `42501 permission denied for schema mktg` while the same key
works fine against `public`.

**Every `snap_*` table and `run_log_reports` has a foreign key to
`run_log.snapshot_date`.** The day row must exist before anything else is
written. `open_day_log` creates it as `running`; `write_day_log` rewrites it
at the end.

**The sync upserts and never deletes.** Anything that shrinks the population
leaves orphans in snapshots already written. No check catches it, the run
output looks clean, and the views keep aggregating the orphans, so the
dashboard shows the old figure while `run_log_reports.metrics` shows the new
one. The next day's run is unaffected: it writes a new snapshot_date and is
clean.

**A falling total is not necessarily a bug.** Deals leave the window when
deleted or merged in HubSpot, not only when amounts change. Two AWS LHR95
deals worth $4,400,000 and $248,444 vanished between 09-02 and 09-08. Nothing
surfaces this; a total that moves by millions needs a deal-level diff.

**`compute_slide15_grain` carries overturned exclusions on purpose.** It
reproduces a specific July 2026 board slide: Amazon dropped, Galco diverted.
Anything needing a real sourced test reads `d["single_program"]` from
`build_dataset`. Using the wrong one cost $4.39M across 10 deals once already.

**Dead code that looks live.** `prior` in `generate_report.main()` is loaded
from `prior_snapshot.json` and never read. `dg_sourced` and `dg_share` in
`generate_netnew_report.main()` are assigned and never read.

**Data gaps that are not code faults.** `sub_vertical` is set on a small
minority of contacts, so most deals carry `Unknown`. About 1,065 of 7,230 SLA
rows have no `hs_v2_date_entered_current_stage`, so their stage ages are null
and drop out of averages rather than counting as zero.

**`is_internal` does no work on `snap_influence`** - zero rows across 128
email domains. It fires correctly on `snap_sourced_contact`.

**Lovable shares one instruction queue.** If Alecia and an agent both send
instructions to `msa-dash-pro`, they interleave and the agent may action the
wrong one or drop into plan mode mid-task. It happened three times in this
session. Let one finish before starting the other.

## Next

1. Apply both staged migrations and run their PASTE 2 blocks:
   `2026-09-14_f_close_rate.sql` and
   `2026-09-14_influenced_pipeline_by_program.sql`. Then regenerate
   `docs/schema.sql`. Nothing reads either yet, so applying them changes no
   page.
2. Build the influenced-pipeline section in `msa-dash-pro`, and apply the
   "Single-program influenced pipeline" label there. Read the labels from
   `config_settings`, do not hard-code. One instruction at a time - the
   Lovable queue is shared.
3. The Lead SLA page is built but has not been reviewed. Given 34 Qualified
   contacts over 90 days, it is the page most likely to prompt action.
4. Decide whether the `--check-schema` negative-test harness should live in
   the repo, and what runs it.
5. Refresh the HubSpot token in the local `config.env`. It returns 401 as of
   2026-09-14. The workflow's own secret is fine - `run_log` is `status=ok`
   with 0 failed reports every day through 09-14 - so this affects local
   runs of the generators only, not the daily sync.
6. Consider folding `config_program_keywords` and `classify_program()` into
   one source. Every other two-sources-of-truth pair on this project has
   diverged eventually.

Done since: extending `--check-schema`, item (h); settling `snap_close_rate`,
item (b); settling the `(multi)` bucket, item (e).
