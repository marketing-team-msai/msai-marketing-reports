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

- `f_sourced_by_program` is program-grain: 5 rows PER SNAPSHOT, not a deal
  count. Four `row_type = 'program'` rows plus one `row_type = 'reconciling'`
  row for multi-program deals. The headline is
  `sum(sourced_pipeline) where row_type = 'program'`, which on 2026-09-14 is
  145 / $8,840,403.98. Summing all five rows adds the reconciling row and is
  wrong; on 2026-09-14 that gives $11,882,363.95. `f_pipeline_model`
  and the /overview tile and chart all filter on `row_type`; anything new
  that reads this function must too. There is no `amount_home` column.
  `v_sourced_by_program` is `select * from f_sourced_by_program(true, null)`,
  deliberately one body so the two cannot drift.
- INFLUENCED PIPELINE IS COUNTED THREE WAYS AND ONLY ONE OF THEM SUMS.
  `f_influenced_pipeline` is the headline: each deal ONCE, 114 /
  $9,533,793.08 on 2026-09-14, with `row_type` `single_program` 71 and
  `multi_program` 43 summing back to it. `f_influenced_by_combination` is
  mutually exclusive, so its rows also sum to that exactly.
  `f_influenced_by_program` DOES NOT SUM: each program carries the full value
  of every deal it touched, so its four rows total $12,464,841.12 against a
  true $9,533,793.08. Take totals from `f_influenced_pipeline`, never by
  adding program rows. Caption from
  `config_settings.label_influenced_by_program`.
- `v_deal_program` is the dedupe grain everything influenced is built on:
  distinct `(snapshot_date, deal_id, program)`, 157 pairs backed by 248
  detail rows, 61 of them multi-row. Summing `snap_influence` rows instead
  gives $39,354,872.17 against a true $9,533,793.08. Do not add a summable
  column to `v_deal_program`, and do not build a dollar figure by summing
  `snap_influence`. `v_influenced_deal_detail` repeats `amount_home` on every
  row by design - it is for listing who and what touched a deal, never for
  dollars.
- The influenced-pipeline objects are NET NEW ONLY; `snap_influence` and
  `f_influence_by_campaign` are PORTAL-WIDE. `snap_influence` holds 136
  distinct deals on 2026-09-14, of which 22 are not Net New and are dropped.
  Their totals will not match and that is correct. Match the filters before
  comparing anything.
- `config_program_keywords` is a GENERATED MIRROR of
  `generate_netnew_report.PROGRAM_KEYWORDS`, not a second source. It was two
  independently hand-maintained copies until 2026-09-14, verified identical
  that day, and certain to have drifted eventually. Now `sync_to_mktg.py
  --sync-keywords` reconciles the table to the Python tuple exactly -
  add/update/remove by keyword - and the daily workflow runs it every day
  (`continue-on-error`, so a transient write failure there never blocks the
  day's actual reports). Edit keywords ONLY in `PROGRAM_KEYWORDS`; the table
  will catch up on the next run, or immediately via
  `python sync_to_mktg.py --sync-keywords`. `program_keyword_rows()` raises
  if a keyword is ever listed under two programs. Query 2.8 in
  `docs/migrations/2026-09-14_influenced_pipeline_by_program.sql` is a
  separate, still-useful check: it verifies the SQL classification against
  the stored `is_single_program` end to end, which catches a bug in
  `v_deal_program` itself, not only a stale table.
- `snap_influence.campaign_type` is NOT the program. It is HubSpot's own
  taxonomy (Content, Event, Webinar, Form, Whitepaper, Video, Case Study, PR)
  and cuts a different way. Program comes only from `classify_program()` /
  `config_program_keywords` over `campaign_name`.
- The single-program rule measures single-program INFLUENCE, not opportunity
  origin. Its display label is "Single-program influenced pipeline", carried
  in `config_settings.label_single_program`. The workbook labels in
  `generate_netnew_report.py` were changed 2026-09-14; the CALCULATION and
  every column name in `f_sourced_by_program` were deliberately left alone,
  because the Lovable dashboard reads `sourced_deals` and `sourced_pipeline`
  by name. The label change still has to be applied in `msa-dash-pro`.
- Every multi-program deal touches exactly TWO programs, 41 of 43 being
  Content & Technology + Events. Content is on 97% of influenced deals,
  Events 39%, PR & Brand 2%, Advertising 0%. So the single-program rule was
  not mis-attributing evenly, it was hiding Events: 94% of Events-touched
  pipeline ($2,907,483.04 of $3,109,583.04) sat in the `(multi)` bucket.
  Even split was considered and NOT used - a program that touched a deal
  shows the whole deal in `f_influenced_by_program`, or the row would be an
  allocation wearing a participation label. `even_split_value` and
  `f_influence_by_campaign` keep their behaviour and are now labelled
  "Allocated influenced pipeline - even split".
- `f_close_rate` is segment-grain and TRIPLE counts across `segment_type`.
  Every closed deal appears once under `'all'`, once under `'amazon'` and
  once under `'vertical'`. 18 rows per snapshot on 2026-09-14; summing all
  of them gives 816 closed / 615 won instead of 272 / 205. Filter on
  `segment_type`, the same discipline `row_type` needs on
  `f_sourced_by_program`. `v_close_rate` is `select * from
  f_close_rate(null)`, one body so the two cannot drift.
- `f_close_rate` returns TWO rates and they are not interchangeable.
  `deal_win_rate` is won/closed by count; `dollar_win_rate` is won/(won+lost)
  by amount. On 2026-09-14 Amazon reads 0.9568 by deal and 0.7186 by dollar -
  it wins nearly every deal and loses the big ones. Never render either as
  "close rate" unqualified. Its population is the Net New Pipeline
  (HubSpot 813739955) create-date cohort: EVERY deal in that pipeline, not
  only marketing-sourced ones, so these are commercial rates, not marketing
  rates. Not comparable to the offsite 0.70 / 0.30 in
  `generate_netnew_report.py` MODEL, which came from a wider book.
- `measurement` on `f_close_rate` is `below_threshold`, deliberately NOT the
  `not_measured` that `f_sourced_by_program` uses. `not_measured` means no
  source is captured; `below_threshold` means captured but under
  `config_settings.close_rate_min_closed` (20), so both rates are null while
  counts still show. Same dash on screen, different reasons.
- `mktg.snap_close_rate` is SUPERSEDED, not unbuilt. It holds 0 rows and
  nothing writes it. It was segment-grain, which made it an aggregate in a
  `snap_` table against the rule in `sync_to_mktg.py`'s own docstring, and
  every input was already in `snap_sourced_deal`. `f_close_rate` replaced it
  with no ETL leg. Kept rather than dropped; that call is still open.
- `measurement` is `not_measured` for any program listed in the
  `unmeasured_programs` row of `config_settings`, currently Advertising.
  That zero means "not captured", not "captured and zero", and renders as a
  dash. `snap_ad_source` is now built (see "Ad source / Windsor" below) but
  the row was deliberately NOT deleted yet - ad spend visibility and
  deal-level attribution are different things, and this still-open call is
  explained there. PR & Brand's zero is genuine and renders as $0.00.
- EVERY `f_*` function returns rows for EVERY `snapshot_date`, not just the
  latest. Always filter, and filter SERVER-side: `.rpc(fn, args).eq(
  "snapshot_date", d)`, or `?snapshot_date=eq.<date>` over HTTP. PostgREST
  caps every response at 1000 rows and the functions order oldest-snapshot
  first, so fetching everything and filtering in the browser silently drops
  the NEWEST snapshot once the payload outgrows the cap - the page then
  renders empty, or worse shows an older snapshot, while the freshness banner
  still reads today. Unfiltered, `f_sourced_by_program` currently totals
  1,909 deals / $116,742,754.74 instead of 145 / $8,840,403.98.
  Fixed in the dashboard 2026-09-14; the views have the same shape, so
  anything new that reads them must filter too.
- `snap_sourced_deal` holds the FULL Net New population (866 rows), not only
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
- The sync UPSERTS and never deletes. Narrowing the window, or anything else
  that shrinks the population, leaves the dropped rows in place in snapshots
  already written. They are invisible to `--check-schema` and to the run
  output, and the views keep aggregating them, so the dashboard goes on
  showing the old figure while `run_log_reports.metrics` shows the new one.
  The next day's run is unaffected: it writes a new `snapshot_date` and is
  clean. Only the already-written snapshot needs a delete.
- `--check-schema` now covers four things, not one: column names, the
  `ON_CONFLICT` target against the real primary key, the foreign keys, and the
  column types against the rows the builders actually produce. It reads all of
  that out of the PostgREST OpenAPI spec it was already fetching - `format`
  carries the Postgres type, and `description` carries `<pk/>` and `<fk .../>`
  markers. No extra request, no DDL. The type check is fed by `_fixture_rows()`,
  the same fixtures `--selftest` uses, deliberately: a separate sample would be
  a second source of truth about what we send. Whatever you add to `COLUMNS`,
  add to those fixtures, or the new columns pass the name diff and are never
  type-checked. Still blind to orphan rows and to anything about row content.
- `docs/schema.sql` is a GENERATED dump of every `mktg` view and function.
  Read it instead of asking for the DDL to be run by hand. It is not applied
  by anything, so it goes stale silently: refresh it whenever a migration
  lands. The regeneration query is in its header.
- The Events page (`docs/migrations/2026-09-14_events_page.sql`) is the
  first place in this schema where `authenticated` can WRITE anything.
  `mktg.event` and `mktg.event_cost` are hand-maintained (name/date/
  location/attendees, and budget vs actual cost), never touched by
  `sync_to_mktg.py`, and writable only by emails listed in
  `mktg.event_editor` - enforced by RLS policies calling
  `mktg.is_event_editor()`, not by a Python check. `event_editor` itself
  has no grants to `authenticated` at all; manage it by hand in the SQL
  editor. An event can map to MORE THAN ONE HubSpot Campaign Influence list
  (`mktg.event_hubspot_list`, discovered 2026-09-14 with The Reliability
  Conference's separate Booth and Collateral lists) - a list still belongs
  to exactly one event (`hubspot_list_id` is UNIQUE there).
  `mktg.snap_event_funnel` is a normal snap_* table (counts only, written
  daily by the new `generate_events_report.py` via `sync_to_mktg.py`).
  `f_event_roi()`/`v_event_roi` join all of these and compute the funnel
  rates, cost-per-stage (off `actual_cost`), a cost-efficiency GOOD/REVIEW
  flag from a live cohort median (recomputed per `snapshot_date`, not a
  fixed baseline), and a separate budget ON BUDGET/OVER BUDGET flag - the
  two flags answer different questions and are deliberately not merged.
  Opportunity here is a contact lifecycle stage, same rule as everywhere
  else - no deals are joined for events, so there is no "influenced
  pipeline $" for events yet; a plausible fast-follow, not built.
  `percentile_cont` cannot take `OVER` (it is an ordered-set aggregate, not
  a window function) - `f_event_roi` computes the median as a `GROUP BY`
  aggregate in its own CTE, joined back by `snapshot_date`, not as a window
  function over the per-event rows directly.

## Window anchor

2026-01-01, set 2026-09-14. Until then the ETL pulled from 2025-06-01 while
`config_settings.window_anchor_netnew` said 2026-01-01, so every caption
reading "Deals created since January 1, 2026" was false and every headline
was computed over about twice the population the label implied - 431 of 866
Net New deals predated the stated window.

The anchor is now 2026-01-01 in all four places: `DEALS_CREATED_SINCE` in the
workflow, `config.env.example`, and the module defaults in
`generate_report.py` and `generate_netnew_report.py`. It already read
2026-01-01 in `config_settings`, which is what the dashboard displays, so the
five now agree. Change all of them together or they will drift again.

Snapshots from 2026-09-02 to 2026-09-14 were written under the old anchor and
still hold the wider population. A trend across that boundary shows a step
down that is a definition change, not a business event. See
`docs/migrations/2026-09-14_window_anchor_2026_cleanup.sql`.

## Population reconciliation (snapshot 2026-09-14, window 2026-01-01)

Verified live 2026-09-14 after the anchor change. These move daily with CRM
activity: re-count before concluding anything is broken, and see the note
below on why totals can fall.

snap_sourced_deal: 436 deals / $33,755,615.79 total, splitting as

    single-program (the headline metric):  71 / $6,602,745.04
    uninfluenced (null program):          322 / $24,221,822.71  [215 are Amazon]
    multi-program:                         43 / $2,931,048.04

snap_influence: 291 rows / 136 distinct deals / $9,603,916.76
snap_sourced_contact: 4,143 | snap_lead_sla: 7,230 | over SLA: 60

Under the old 2025-06-01 anchor the same snapshot read: 866 deals /
$44,914,165.00, sourced 145 / $8,840,403.98, uninfluenced 675 /
$33,031,801.05, multi-program 46 / $3,041,959.97; snap_influence 422 rows /
231 deals / $12,046,458.76. Moving the anchor cut sourced pipeline 25% and
influenced pipeline 20%. Neither set was wrong arithmetic; they answer
different questions.

`f_sourced_contacts_by_stage` totals 4,388, not 4,406: it excludes the 18
`is_internal` contacts. That gap is by design, not a miscount.

The population total can FALL between snapshots without anything being wrong.
Deals disappear from the window when they are deleted or merged in HubSpot,
not only when their amount changes. Between 09-02 and 09-08 two AWS LHR95
deals worth $4,400,000 and $248,444 left the population entirely, which is
most of the drop from $49.15M to $44.91M. Nothing surfaces this, so a total
that moves by millions overnight needs a deal-level diff, not a bug hunt.

For the record, 2026-09-02 was: 861 deals / $49,154,033.88, single-program
148 / $9,237,904.98, uninfluenced 671 / $37,463,872.93, multi-program
42 / $2,452,255.97; snap_influence 359 rows / 228 deals / $11,842,231.76.

## Cross-table drilldown

`snap_influence` and `snap_sourced_deal` are NOT comparable as totals -
portal-wide versus Net New only - but they DO join cleanly on
(snapshot_date, deal_id) for deal-level detail. Verified 2026-09-14: all 145
single-program and all 46 multi-program deals appear in `snap_influence`,
100% of both. So any Net New deal that is influenced can show its contacts
and campaigns by joining across.

The 675 uninfluenced deals have no rows in `snap_influence` by definition.
That is the correct answer to "which campaigns touched this deal", not a gap.

One caveat when showing dollars in such a drilldown: `even_split_value` is
computed across the portal-wide influence population, so those shares do not
sum to sourced pipeline and must not be presented as if they do.

## Ad source / Windsor

WIRED IN 2026-09-15. `sync_to_mktg.py`'s fifth leg, `ad_source`, now calls
`generate_report.pull_windsor_daily()` and writes `mktg.snap_ad_source` daily.
`pull_windsor()` (whole-window totals, one row per source) is unchanged and
still feeds only the standalone workbook run - a separate function so that
path could not regress.

- Grain is `(metric_date, source, account)` per snapshot_date, matching the
  table's actual primary key (`snapshot_date, metric_date, source, account`),
  not one row per source like the workbook path. Every run re-pulls and
  upserts the WHOLE `WINDSOR_DATE_PRESET` trailing window (default
  `last_365d`), which is what backfilled history on the first run rather than
  a separate backfill process - there is no `is_seeded = true` data here, by
  the same "this script always writes is_seeded = false" rule as everything
  else it writes.
- `is_paid` is decided PER ROW (`spend > 0`), not per source. Verified live
  2026-09-15: `google` carries both paid rows (spend > 0, Google Ads) and
  organic rows (spend = 0, organic search) under the same source name in the
  same window, so a fixed paid-source list would misclassify one of them.
  This is the same spend>0 rule the workbook's paid/organic split already
  used, just applied at day grain instead of collapsed over the whole
  window - not a new rule.
- First live run (2026-09-15): 710 rows, `metric_date` 2025-12-02 to
  2026-09-14, $49,590.72 total spend - $25,176.12 google, $15,443.40
  linkedin, $8,971.20 reddit, $0 bing. Re-verify before trusting these; they
  move with Windsor's own trailing window on every run, same as the deal
  population moves in the population-reconciliation section above.
- The GitHub Actions workflow now writes `WINDSOR_API_KEY` /
  `WINDSOR_DATE_PRESET` into `config.env` from a `WINDSOR_API_KEY` repo
  secret. If that secret is not set, `ad_source` logs "not set" and writes
  nothing - it does not fail the run or the other four reports.
- `config.env.example` and a local `config.env` still document/carry the same
  key; nothing changed there beyond a comment.

Two things this does NOT do, and nobody has decided to do yet:

- `mktg.v_ad_performance` groups by `snapshot_date` (not `metric_date`), so
  for any given day's snapshot it sums spend/clicks/etc across the ENTIRE
  trailing window, not per-metric_date. That reads as "cost so far in the
  trailing window", not a day-by-day trend - confirmed live, its per-source
  totals for 2026-09-15 equal the whole-window sums above. `snap_ad_source`
  itself keeps full `metric_date` granularity; nothing has decided whether
  `v_ad_performance` should be rebuilt to expose a trend, and it was not
  touched here since changing what it aggregates is a grain change, not the
  mechanical fix this leg was.
- `unmeasured_programs` (see the gotcha above) still lists Advertising, and
  the config row was NOT deleted here even though CLAUDE.md previously said
  to delete it once `snap_ad_source` was built. Ad spend and clicks now
  exist, but `f_sourced_by_program`'s Advertising figure is still $0 for the
  same reason as before - almost no Campaign Influence list membership ties a
  deal to Advertising - and that has not changed. Deleting the row would make
  that $0 render as measured, which is a different, still-open claim from
  "we can now see ad spend." Left for a deliberate decision, not assumed.

Paid attribution (tying spend to a deal or to sourced pipeline) still has no
path. Nothing in the Campaign Influence lists carries it, and `snap_ad_source`
has no deal_id - it is spend/clicks/conversions by source and account, not
attribution.

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
