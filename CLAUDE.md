# MSAI Marketing Reports

Three HubSpot reports synced daily into the `mktg` schema in Supabase by
`sync_to_mktg.py`. The `snap_*` tables hold entity-grain detail; the views and
functions own all aggregation.

## Ratified rules

- `is_single_program` is false for uninfluenced (null program) and
  multi-program deals. All sourced-pipeline metrics currently exclude both.
  This governs the headline number and was previously undocumented.
  SCOPE, clarified 2026-09-15: this rule governs `f_sourced_by_program` /
  `snap_sourced_deal` (Net New / "sourced") ONLY. The influence side
  (`f_influenced_by_program`, `f_influenced_pipeline`, `v_deal_program`)
  never had an exclusivity rule for its overall total and, as of
  2026-09-15, has no exclusivity concept anywhere - see "Real
  campaign_type" below. Do not assume a change to one side implies the
  other; they now use different classification mechanisms entirely
  (keyword-guessed `campaign_name` for sourced, real HubSpot
  `campaign_type` for influence).
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
  `unmeasured_programs` row of `config_settings` - there was one such
  program, Advertising, until the row was DELETED 2026-09-15 (see "Ad
  source / Windsor" below for why). With no row present,
  `coalesce((select array(...) from config_settings where key =
  'unmeasured_programs'), '{}'::text[])` falls back to an empty array, so
  every program now measures. Verified live: Advertising renders
  `measurement = 'measured'`, `sourced_deals = 0`, `sourced_pipeline = 0`
  for snapshot 2026-09-15 - the same genuine-zero shape PR & Brand already
  had. If a program with no measurement path at all shows up again, the
  fix is to re-insert this config row (see the 2026-09-02
  `program_row_type` migration for the exact insert), not to invent a
  second mechanism.
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

- WEBINARS PROGRAM, added 2026-09-15 (SUPERSEDED ON THE INFLUENCE SIDE
  the same day - see "Real campaign_type" below. `f_influenced_by_program`
  no longer reads `config_program_keywords` at all, and its 10-bucket
  `programs` list replaced the 5-bucket one this entry describes. This
  entry's `f_sourced_by_program` / sourced-pipeline content is still
  accurate and current; read its influence-side content as history, not
  current behavior). Webinar campaigns previously fell
  into the Content & Technology catch-all because no keyword in
  `PROGRAM_KEYWORDS` matched them. `generate_netnew_report.PROGRAM_KEYWORDS`
  now has a fifth entry, `("Webinars", 4, ("webinar",))`, and
  `f_sourced_by_program` / `f_influenced_by_program` each have a fifth row
  in their `programs` VALUES list. See
  `docs/migrations/2026-09-15_add_webinars_program.sql`.
  TWO SPEEDS, BY DESIGN: `f_influenced_by_program` /
  `f_influenced_pipeline` / `f_influenced_by_combination` read
  `v_deal_program`, which classifies from `config_program_keywords` at
  QUERY time, so every historical snapshot's influenced-by-program numbers
  moved the moment `--sync-keywords` ran - Content & Technology's
  historical total dropped by whatever was Webinar-only. `f_sourced_by_program`
  reads `snap_sourced_deal.program` / `.is_single_program`, which
  `generate_netnew_report.py` computes in Python and freezes into the row
  at ETL write time - already-written snapshot_dates keep their old
  classification. Sourced-by-program only shows Webinars from the next
  daily run's new `snapshot_date` forward. A backfill of historical
  `snap_sourced_deal` rows to match was considered and deliberately not
  done - prospective-only was judged sufficient and a backfill would be a
  bigger, less reversible rewrite of already-written snapshot data.
  `compute_slide15_grain` in `generate_netnew_report.py` reproduces a FIXED
  July 2026 offsite slide with only the original four buckets
  (`PROGRAMS`/`SLIDE15`) - it folds any Webinars-classified deal into
  Content & Technology rather than adding a fifth bucket, so that frozen
  historical comparison doesn't move. The Lovable dashboard (`msa-dash-pro`,
  separate project) still needs updating to expect a fifth program row -
  not done as part of this change, same open item pattern as the
  single-program label change noted below.

- REAL campaign_type, wired in 2026-09-15. HubSpot added a genuine custom
  property, `campaign_type`, on the NATIVE Marketing Campaign object (not
  the Campaign Influence Lists this ETL reads directly) - a controlled
  24-value picklist (Case Study, Collateral, Email - Bespoke, Email -
  Database, External Contributed Article, External Event, Organic Social,
  Outsourced SDR, Paid Search, Paid Social, PR, Product Launch, Research
  Paper, Survey, Video, Web Ads - External, Web Ads - Own, Web Content -
  ICI, Web Content, Webinar, Webinar - Own, Website Form - ICI, Website
  Form, Whitepaper), backfilled and populated. Reading it needed the
  `marketing.campaigns.read` scope added to the HUBSPOT_TOKEN private app
  - without it, `/marketing/v3/campaigns/*` 403s outright.
  THE LINK: each Campaign Influence list's filter branch contains a
  `hs_marketing_campaign_object_id` filter whose value's last
  `-`-separated segment is that native Campaign's `hs_object_id` -
  verified live against list 4463 ("MSAI 2026 Blog Content" ->
  campaign_type "Web Content"). `generate_report.pull_native_campaigns()`
  / `list_linked_campaign_type()` do this resolution; `classify_campaign()`
  (the old name-keyword guess) is now FALLBACK ONLY, for the 8 paid-ad
  lists (LinkedIn/Google/Meta) built on ad-platform filters with no
  Campaign link, plus any similarly orphaned list (1 found 2026-09-15,
  "Partnerships 2026" - its linked object id wasn't among the 115
  campaigns fetched, likely archived).
  ONE REAL SURPRISE, worth remembering when a program number looks off:
  "Campaign Influence: 7x24 Exchange Tradeshow" is named like an event,
  but its linked Campaign's campaign_type is "External Contributed
  Article" (the actual campaign is a magazine byline). Trusting the real
  property over the list's own name is the whole point of this change -
  don't "fix" a case like this back to matching the name.
  `generate_report.CAMPAIGN_TYPE_PROGRAM` groups the 24 real values (plus
  classify_campaign()'s 4 fallback-only outputs: Blog, Event, Form,
  Content) into 10 broader INFLUENCE-side program buckets: Content
  (web content, collateral, case studies, whitepapers, research papers,
  video, surveys, blog), Webinars, Events (external + internal/onboarding
  - "Event - Internal", e.g. Amazon Onboarding & Training, is INCLUDED
  deliberately per Alecia: onboarding matters for adoption), Web Forms,
  Product Launch, PR & Media (PR + contributed articles), Email,
  Organic Social, Advertising, Outsourced SDR (kept as its own bucket,
  not folded into anything, per Alecia: "we see it as a campaign"). THE
  SINGLE SOURCE for `mktg.config_campaign_type_program` -
  `sync_to_mktg.py --sync-campaign-types` reconciles that table to this
  dict exactly, same add/update/remove pattern as
  `--sync-keywords` / `config_program_keywords`. Edit groupings ONLY in
  the Python dict. Wired into the daily workflow, `continue-on-error`,
  same as the keyword sync.
  Deliberately separate from `generate_netnew_report.PROGRAM_KEYWORDS`,
  which still governs the unchanged sourced-pipeline side - see the
  ratified-rules note above.
  MECHANISM CHANGE: `v_deal_program` now joins
  `snap_influence.campaign_type` (real value, frozen per snapshot at ETL
  time) against `config_campaign_type_program`, instead of
  POSITION()-matching keywords in `campaign_name` at query time. This
  means influence classification is now ALSO frozen per snapshot going
  forward (not query-time-retroactive the way it was through
  2026-09-15) - a new daily run's snapshot picks up whatever
  `campaign_type` HubSpot holds that day; an old snapshot's rows keep
  whatever `campaign_type` was frozen in when they were written.
  `v_influenced_deal_detail`'s per-row `program` column had its own
  separate inline keyword lookup (duplicating v_deal_program's logic at
  row grain) - also moved to the same join, so the two can't disagree.
  EXCLUSIVITY RETIRED FOR INFLUENCE. The old sourced-style rule (every
  touch must map to the same program, or the deal is excluded) was NEVER
  actually load-bearing for `f_influenced_pipeline`'s overall total - that
  already counted each influenced deal once regardless of touch count.
  It WAS the reason `f_influenced_by_program`'s per-program breakdown kept
  shrinking toward uselessness as buckets got more precise: at full
  ~20-bucket granularity (verified live 2026-09-15, ex-Amazon), single-
  program deals fell to 50 / $1.6M while PR, Case Study, Whitepaper,
  Research Paper, Video, Collateral, Web Content, Paid Search/Ads,
  Outsourced SDR, Survey, and Email all showed a permanent $0 - not
  because there was no activity, but because those types essentially
  never occur as a deal's ONLY touch. Decided 2026-09-15: touch breadth
  is a metric to report, not a filter. Verified live: deals touched by
  3+ programs carried $6,487,418 across 37 deals - more than the 50
  single-program ($1,596,205) and 21 two-program ($1,198,645) deals
  combined. Hiding multi-touch deals was hiding the biggest ones.
  `mktg.v_deal_touch_summary` (new view) answers "how many campaigns (and
  which programs) influenced this deal" directly: one row per
  (snapshot_date, deal_id) with `campaign_count` (distinct Campaign
  Influence lists), `program_count` (distinct broader programs), and
  `programs` (array of which). No deal is ever excluded from it.
  `f_influenced_by_program`'s `programs` VALUES list moved from the old 5
  (Content & Technology / Events / Advertising / PR & Brand / Webinars) to
  the new 10 above - same `not_measured` genuine-zero mechanism via
  `config_settings.unmeasured_programs`, unchanged.
  NOT IN SCOPE, and not done here: "sourced" pipeline (was this deal's
  CONTACT'S lead source marketing-originated) is a different question
  entirely from campaign influence, and needs its own future project
  mapping HubSpot Lead Source values - not a campaign classification
  problem, and not solved by anything in this entry.

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

`v_ad_performance` NOW GROUPS BY `metric_date` TOO, fixed and verified live
2026-09-15 (`docs/migrations/2026-09-15_v_ad_performance_metric_date.sql`).
Before this it grouped by `snapshot_date` only, so any given day's snapshot
summed spend/clicks/etc across the ENTIRE trailing window rather than per
day - it read as "cost so far in the trailing window", not a trend, even
though `snap_ad_source` itself always held full daily grain. Confirmed
live: `snapshot_date = 2026-09-15` now returns 710 rows spanning 255
distinct `metric_date` values (2025-12-02 to 2026-09-14), and the single
newest day (`metric_date = 2026-09-14`) returns exactly one row (google /
MultiSensor AI & ICI, $58.19) instead of the whole window. The migration
had to `DROP` and recreate the view rather than `CREATE OR REPLACE`,
because Postgres only allows new columns appended at the end of an
existing view's column list, not inserted in the middle - so the grant to
`authenticated` is re-issued inside the same migration, same trap as the
function-signature case above.

THIS VIEW CAN NOW APPROACH POSTGREST'S 1000-ROW CAP ON A SINGLE
`snapshot_date`, unlike every other `f_*`/`v_*` object in this schema.
Because every daily sync rewrites the WHOLE trailing window under that
day's snapshot_date, one snapshot_date alone already carries 710 rows
today. At the current pace (~2.8 rows per calendar day) a full `last_365d`
window projects to roughly 1,015 rows for a single snapshot_date - over
the cap, with no second filter dimension available the way `row_type` or
`segment_type` give the other functions one. Filtering server-side on
`snapshot_date` is necessary here but is NOT guaranteed sufficient the way
it is everywhere else. Re-count before building anything against this
view; if it is at or near four digits, page through `metric_date` rather
than trusting one unfiltered response.

The `unmeasured_programs` config row for Advertising was DELETED 2026-09-15
(a deliberate decision, made explicitly, not a side effect of building the
ETL leg above - see the gotcha above for the mechanics). This makes
Advertising's `f_sourced_by_program` figure render as a genuine `$0.00`
instead of a dash. Read that as "ad spend is now visible", NOT as "deal
attribution to Advertising now works" - those remain two different facts.
`f_sourced_by_program`'s Advertising number is still $0 for the same
reason as always: almost no Campaign Influence list membership ties a
deal to Advertising. Nothing about that changed; only what the zero
renders as changed.

Paid attribution (tying spend to a deal or to sourced pipeline) still has no
path. Nothing in the Campaign Influence lists carries it, and `snap_ad_source`
has no deal_id - it is spend/clicks/conversions by source and account, not
attribution.

## Marketing Sourced (replaces the old "Net New / Sourced" page)

WIRED IN 2026-09-16. Alecia flagged that the "Net New / Sourced" page was
being read as "was this deal marketing-sourced" when `is_single_program` /
`f_sourced_by_program` actually measure something else entirely: whether
every campaign touching a deal's contacts happened to map to ONE program
bucket. That is campaign touch breadth, not opportunity origin, and
neither concept anywhere in this schema looked at deal type or contact
lead source before this - both were flagged as future work back in the
2026-09-15 campaign_type migration ("the Net New/'sourced' side is a
genuinely different question... pending its own future rework") and
confirmed as genuinely absent by a live grep before building this.

THE ACTUAL QUESTION, per Alecia 2026-09-16: for a NEW BUSINESS deal, does
the associated contact's lead source indicate marketing origin (e.g.
Trade Show), AND did a marketing campaign actually touch the deal. BOTH
signals are required to agree - not either-or, not lead-source-primary.
A deal with only one signal is real and reportable, just not counted as
Marketing Sourced.

TWO NEW HUBSPOT PULLS, neither existed before this:
- `dealtype` (deal property, picklist): `newbusiness` / `existingbusiness`
  / `Renewal`. Renewal groups with Existing Business as repeat business,
  per Alecia - not its own bucket, not excluded.
- `lead_source` (CONTACT property - a custom MSAI picklist, NOT the
  standard `hs_analytics_source` "Original Traffic Source", and NOT the
  near-empty `lead_source__c` that lives on the deal). Confirmed live
  against the portal's Properties API 2026-09-16: `lead_source` has 33
  values including "Trade Show", "Trade Show Lead", "Outsourced SDR",
  "Cold Call", etc - `hs_analytics_source` is a different, HubSpot-
  standard, auto-tracked field with only 10 broad values (Organic
  Search, Paid Search, Email Marketing, ...). Do not conflate the two.
  There is also `hs_sourced_contact_origin` on contacts - that is which
  SALES-PROSPECTING TOOL (Apollo, ZoomInfo, Seamless, LinkedIn, ...)
  sourced the contact, unrelated to marketing origin. Not used here.

`generate_netnew_report.LEAD_SOURCE_BUCKET` is THE SINGLE SOURCE for
lead_source -> bucket (marketing / sales / other), same
generated-mirror pattern as `PROGRAM_KEYWORDS` /
`CAMPAIGN_TYPE_PROGRAM`: `mktg.config_lead_source_bucket` is reconciled
by `sync_to_mktg.py --sync-lead-source-buckets`, wired into the daily
workflow with the same `continue-on-error` treatment as the other two
keyword/mapping syncs. Edit bucket assignments ONLY in the Python dict.
Ratified bucket calls, per Alecia 2026-09-16 (the ones that are not
obvious from the label alone): Outsourced SDR, Email, Incoming Email,
Incoming Call, Referral, and AI Assistants/Browser all count as
marketing; Reliabilityweb and WTWH Media (media-partner content) count
as marketing; "List Vendor" (label "List Upload or Vendor") counts as
SALES, not marketing, unless a specific list is confirmed to be event-
attendee sourced - no such override mechanism exists yet, a plausible
fast-follow.

`snap_sourced_deal` gains 7 columns, computed once in Python at ETL
write time (same frozen-per-snapshot treatment `program` /
`is_single_program` already have on this table - see the Webinars
gotcha above for why that matters): `deal_type`, `is_new_business`,
`has_marketing_lead_source`, `marketing_lead_sources` (text[], every
distinct marketing-bucketed lead_source value across ALL of the deal's
associated contacts, any contact counts - reported for transparency,
NEVER summed), `primary_lead_source` (the one such value from whichever
contact was created earliest - exclusive per deal, this is what
by-lead-source dollar breakdowns group on, the same exclusivity trick
`is_single_program` relies on for by-program breakdowns), `marketing_sourced`
(bool), and `sourcing_status` - one of `marketing_sourced`,
`partial_lead_source_only`, `partial_campaign_only`,
`not_marketing_sourced`, `repeat_business`, `unknown_deal_type`. The two
`partial_*` statuses are kept visible on purpose - a deal where the two
signals disagree is exactly the interesting case, not noise to average
into `not_marketing_sourced`.

THREE NEW QUERY OBJECTS, all EVERY-`snapshot_date` / filter-server-side
the same as every other `f_*`/`v_*` here: `f_marketing_sourced`
(-> `v_marketing_sourced`) is the headline, one row per
`(snapshot_date, sourcing_status)`. `f_marketing_sourced_by_lead_source`
(-> `v_marketing_sourced_by_lead_source`) and
`f_marketing_sourced_by_program` (-> `v_marketing_sourced_by_program`)
both filter to `sourcing_status = 'marketing_sourced'` only and group on
`primary_lead_source` / `program` respectively - both exclusive per deal,
so both sum safely. See `docs/migrations/2026-09-16_marketing_sourced.sql`.

PROSPECTIVE ONLY, same precedent as Webinars (2026-09-15): `deal_type`
and `lead_source` were never pulled before this, so every already-
written `snapshot_date` shows 100% `unknown_deal_type` until the next
daily run writes a new one. Not a bug; no backfill was scoped or done,
same reasoning as every other prospective-only change here - rewriting
already-written snapshot rows is bigger and less reversible than letting
the population build going forward.

AT THE TIME THIS WAS WRITTEN (2026-09-16, before the repoint below),
this did not touch `f_sourced_by_program` / `is_single_program` /
`config_program_keywords` / `PROGRAM_KEYWORDS` - see "Sourced program
repointed to real campaign_type" immediately below for why that changed
the very next day, and what did and did not move as a result.
The Lovable dashboard's OLD "Net New / Sourced" page (single-program /
multi-program) still needs to be pointed at the new objects above and
the old framing retired from that page - a separate, not-yet-done change
in `msa-dash-pro`, same open-item pattern as every prior label change
noted elsewhere in this file.

## Sourced program repointed to real campaign_type (reverses a 2026-09-15 boundary)

WIRED IN 2026-09-16, same day as Marketing Sourced above, as a direct
follow-up to it. The Marketing Sourced page surfaced a real
inconsistency: its per-deal "Program" and "By Program" breakdown read
`snap_sourced_deal.program`, which still held the RETIRED keyword-over-
campaign_name classification (Content & Technology / Events /
Advertising / PR & Brand / Webinars) - so the same deal could show
"Content & Technology" on one part of the page next to "Content" or
"Web Forms" from the real-campaign_type-based influence side. Alecia
asked for `snap_sourced_deal.program` / `is_single_program` to be
repointed at the same `v_deal_program` mechanism the influence side has
used since 2026-09-15.

THIS DELIBERATELY REVERSES THE "DO NOT TOUCH" BOUNDARY the 2026-09-15
campaign_type migration drew around `f_sourced_by_program`,
`snap_sourced_deal`, and `is_single_program` ("a genuinely different
question... pending its own future rework"). That boundary was the
right call at the time; this is an explicit, informed follow-up
decision, not a correction of a mistake. Before proceeding, Alecia was
told the concrete consequences and chose to proceed anyway:
  - `f_sourced_by_program` hardcoded the OLD 5-bucket list in its own
    `programs` CTE. Left alone, it would have silently UNDERCOUNTED
    (not relabeled) any deal now falling under a new-taxonomy-only name
    (Content, Web Forms, Product Launch, Organic Social, Outsourced
    SDR, Email, PR & Media) - those deals would match none of the 5
    hardcoded rows and vanish from every per-program total. Fixed in
    the same migration (below).
  - `is_single_program`'s exclusivity is now evaluated against the
    finer 10-bucket real-campaign_type taxonomy instead of the old 4/5
    buckets - the same mechanism change that measurably shrank the
    single-program population on the INFLUENCE side (see "Real
    campaign_type" above: 71 -> 60 -> 51 -> 50 ex-Amazon as buckets got
    finer). Confirmed live 2026-09-16: sourced went from 61 deals under
    the single "Content & Technology" bucket to 36 Content + 16 Web
    Forms, with 9 of the old 61 moving into `(multi)` instead (48 -> 57
    multi-program deals). `f_sourced_by_program`'s row_type='program'
    headline moved from the old figure to 58 deals / $2,030,155, with
    57 multi-program deals worth $7,616,063 in the reconciling row.
    Exclusivity itself was NOT retired here (unlike the influence side)
    - `is_single_program` still means exactly what ratified rule 1 always
    said, just evaluated against the current taxonomy.

WHAT CHANGED, MECHANICALLY:
  - `generate_netnew_report.py`: NO CHANGE. `classify_program()` /
    `PROGRAM_KEYWORDS` / `PROGRAMS` / `compute_slide15_grain()` are
    untouched - they remain the Excel workbook's own in-memory
    classification for that separate deliverable, per its own
    docstring. They are simply no longer written to Supabase.
  - `sync_to_mktg.rows_sourced_deal()`: `program` / `is_single_program`
    now write `None` / `False` placeholders instead of
    `d.get("program")` / `d.get("single_program")`.
  - `sync_to_mktg.repoint_sourced_program(snapshot_date)` (new): reads
    `mktg.v_deal_program` for that date (unchanged view - already the
    correct derivation), collapses to one `(program, is_single_program)`
    pair per deal, and writes ONLY those two columns into
    `snap_sourced_deal`. Nothing here hardcodes the program list.
    `FIRST_CAMPAIGN_TYPE_SNAPSHOT = '2026-09-15'` - dates before this
    are skipped, not guessed at, because `snap_influence.campaign_type`
    for those dates was frozen before the real-campaign_type pull went
    live and does not reliably join through
    `config_campaign_type_program`.
  - Wired into the daily run automatically, right after both the
    influence and netnew jobs finish in the same invocation (skipped,
    not guessed, if a run only includes one of them - e.g. `--only
    netnew` alone).
  - `sync_to_mktg.py --backfill-sourced-program` (new flag): reran this
    for every existing `snapshot_date`. 2026-09-02 through 2026-09-14
    were left alone (predate real `campaign_type`); 2026-09-15 and
    2026-09-16 were rewritten.
  - `mktg.f_sourced_by_program`: its `programs` CTE changed from a
    hardcoded VALUES list to `select distinct program from
    config_campaign_type_program` - everything else about the function
    (row_type discipline, the `(multi)` reconciling row, the
    `not_measured` mechanism) is unchanged. `v_sourced_by_program` picks
    this up automatically (one body, as always).

A REAL BUG WAS CAUGHT AND FIXED DURING THIS ROLLOUT, worth remembering
as a general caution: the first version of the `programs` CTE above
wrote `select distinct program, row_number() over (order by program)...
from config_campaign_type_program` - since `row_number()` is a window
function evaluated per underlying row (one row per `campaign_type`, ~24
of them) BEFORE `distinct` can collapse anything, every row got its own
number and `distinct` had nothing left to deduplicate: each program
came back once per campaign_type that maps to it (Content appeared 10
times, for instance), all with identical counts and dollars, which
would have multiplied `f_pipeline_model`'s sum by however many
campaign_types shared a program. Caught by inspecting live output
before the backfill ran, not by test coverage - there is no automated
test over this SQL function. Fixed by collapsing to distinct program
names in a subquery BEFORE applying `row_number()`. If a future
`f_*`/`v_*` object here ever needs "number these distinct values,"
apply `distinct` first, in its own subquery - never in the same
`select` list as the window function.

WHAT DOES NOT CHANGE: `v_deal_program`, `f_influenced_by_program`,
`v_deal_touch_summary`, `config_campaign_type_program`,
`generate_report.CAMPAIGN_TYPE_PROGRAM` - all untouched, all already
correct. `f_marketing_sourced_by_program` needed NO change - it already
read `snap_sourced_deal.program`, which this repoint makes correct at
the source instead of requiring its own query-time join.
`config_program_keywords` / `PROGRAM_KEYWORDS` are left in place
(harmless, nothing in `mktg` reads them anymore) rather than dropped -
same "leave it, drop by hand only if certain" convention as
`config_campaign_type_program` was left in the 2026-09-15 down
migration. See
`docs/migrations/2026-09-16_sourced_program_from_campaign_type.sql`.

## MQLs by quarter

BUILT 2026-10-04 for a tile + quarter-over-quarter chart on the Pipeline
Influence page. Definition, per Alecia: a contact whose Lead Status
(`hs_lead_status`) ENTERED "Awaiting Sales Qualification" - or the value
`Returning Customer`, labelled "Awaiting Sales Qualification - Returning" -
in the quarter, and whose Lead Status TODAY is not `JUNK` or `Disqualified`.
Once per contact per quarter; re-entry in a later quarter counts again.
US Central quarters, computed in SQL.

- Source is the `hs_lead_status` PROPERTY HISTORY. `previous_lead_status`
  is NOT usable: it holds labels not values, and on 2026-10-04 disagreed
  with history on 49,240 of 49,505 contacts (usually holding the CURRENT
  status). `lead_status___last_updated_date` IS reliable enough to narrow
  who gets re-read (caught 363 of 363 ASQ entrants since 2026-09-01), and
  that is all it is used for.
- `generate_mql_report.MQL_EXCLUSIONS` is the single source for exclusions,
  frozen into `snap_mql_entry.exclusion_reason` at ETL time. Excluded rows
  are still written. Two, both ratified 2026-10-04:
  `workflow_misfire_2026_05_25` (a workflow set ~5,800 List Vendor contacts
  to ASQ, partly restored the same day; would add ~4,640 to Q2) and
  `nurture_recycle_batch_2026_09_21` (122 Nurture contacts moved by one
  automated batch, mostly straight back; manual entries that day count).
- `snap_mql_entry` is ENTRY grain, not contact grain: count DISTINCT
  `contact_id`, never rows. `f_mql_by_quarter()` / `v_mql_by_quarter`
  does; every snapshot_date, filter server-side as always.
- Incremental: each run re-reads the previous snapshot's contacts plus
  anyone with `lead_status___last_updated_date` within 3 days of it plus
  anyone in an entry status now. ~30 seconds a day. First run, and every
  Sunday in the workflow (`--mql-full`), reads all ~49.5k contacts,
  15-20 minutes. `run_mql` deletes today's rows before writing, the one
  place the sync deletes snapshot rows, so a same-day re-run cannot orphan.
- Verified 2026-10-04 from a full read: Q1 126 entered / 73 MQL, Q2 228 /
  192, Q3 265 / 213. The "today" rule penalises older quarters (Q1 lost 53
  to Junk/DQ, Q3 52 of a larger base), so part of the upward trend is
  definitional. The status first appears in history in August 2025;
  nothing earlier is comparable.
- HubSpot's lifecycle "MQL" date (`hs_v2_date_entered_marketingqualifiedlead`)
  is a different measure and was hit by the same 05-25 misfire. Not used.
- See `docs/migrations/2026-10-04_mql_by_quarter.sql`.

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
