-- =====================================================================
-- UP: repoint snap_sourced_deal.program / is_single_program from the
--     retired keyword-over-campaign_name classification to the same
--     real-campaign_type mechanism the influence side already uses,
--     and stop f_sourced_by_program hardcoding the old 5-bucket list
-- =====================================================================
-- Down version: 2026-09-16_sourced_program_from_campaign_type.down.sql
--
-- SCOPE - READ THIS FIRST
--   This REVERSES the explicit "do not touch" boundary drawn in
--   2026-09-15_influence_program_from_campaign_type.sql, which said in
--   its own header: "It does NOT touch mktg.f_sourced_by_program,
--   mktg.snap_sourced_deal, is_single_program, or
--   generate_netnew_report.PROGRAM_KEYWORDS." That was the right call
--   at the time - this is a deliberate, explicit follow-up decision by
--   Alecia on 2026-09-16, made after being told the concrete
--   consequences below, not an oversight being corrected.
--
-- WHY
--   The new Marketing Sourced page (2026-09-16_marketing_sourced.sql)
--   shows a per-deal "Program" and a "By Program" breakdown sourced from
--   snap_sourced_deal.program - which still held the OLD keyword-over-
--   campaign_name classification (Content & Technology / Events /
--   Advertising / PR & Brand / Webinars). Every other program-shaped
--   thing on this dashboard (f_influenced_by_program, v_deal_program,
--   v_deal_touch_summary) has used the real HubSpot campaign_type
--   taxonomy (Content / Webinars / Product Launch / Events / Web Forms
--   / PR & Media / Email / Organic Social / Advertising / Outsourced
--   SDR) since 2026-09-15. Confirmed live 2026-09-16: the Marketing
--   Sourced page showed "Content & Technology" next to deals whose
--   influence records classified them as "Content" or "Web Forms" -
--   the same deal, two different program vocabularies, on one page.
--
--   CONSEQUENCES ALECIA WAS TOLD BEFORE CHOOSING THIS PATH:
--     - f_sourced_by_program hardcodes the OLD 5-bucket list in its own
--       `programs` CTE. Left alone, any deal now classified under one
--       of the new taxonomy's other names (Content, Web Forms, Product
--       Launch, Organic Social, Outsourced SDR, Email, PR & Media)
--       would silently stop matching any of those 5 rows and vanish
--       from f_sourced_by_program's per-program breakdown and totals -
--       not a relabel, a silent undercount. Fixed below by the same
--       migration, per her explicit instruction to "check whether any
--       OTHER... object still writes or returns the old bucket names...
--       and fix those the same way."
--     - is_single_program's exclusivity is now evaluated against the
--       finer 10-bucket taxonomy instead of the old 4/5-bucket one.
--       The 2026-09-15 migration measured that this exact move shrank
--       the single-program population on the influence side (71 -> 60
--       -> 51 -> 50, ex-Amazon) - the same effect should be expected
--       here. This was the whole reason exclusivity was retired on the
--       influence side; it is NOT being retired here, only repointed -
--       is_single_program keeps meaning exactly what ratified rule 1
--       always said (false for uninfluenced and multi-program deals),
--       just evaluated against the current, not the retired, taxonomy.
--
-- WHAT CHANGES, MECHANICALLY
--   1. generate_netnew_report.py: NO CHANGE. classify_program() /
--      PROGRAM_KEYWORDS / PROGRAMS / compute_slide15_grain() are left
--      exactly as they were - they remain the Excel workbook's own
--      in-memory classification for its separate deliverable, per its
--      own docstring. They are simply no longer written to
--      mktg.snap_sourced_deal.
--   2. sync_to_mktg.rows_sourced_deal(): program / is_single_program now
--      write None / False as neutral placeholders instead of
--      d.get("program") / d.get("single_program") - the real value is
--      written immediately after by the new step below, for any
--      snapshot_date where it can be computed.
--   3. sync_to_mktg.repoint_sourced_program(snapshot_date) (new): reads
--      mktg.v_deal_program for that date (already the correct
--      real-campaign_type-through-config_campaign_type_program
--      derivation, no SQL change needed to that view), collapses to one
--      (program, is_single_program) pair per deal_id exactly like
--      v_deal_touch_summary's program_count already does, and writes it
--      into snap_sourced_deal - touching ONLY those two columns.
--      Skips (does not blank) a date if snap_sourced_deal or
--      snap_influence has no rows for it yet, or if the date predates
--      FIRST_CAMPAIGN_TYPE_SNAPSHOT = '2026-09-15' - snap_influence.
--      campaign_type for earlier dates was frozen before the real-
--      campaign_type pull went live (see
--      2026-09-15_influence_program_from_campaign_type.sql) and does
--      not reliably join against config_campaign_type_program. Reads
--      the program list from config_campaign_type_program /
--      v_deal_program at run time - nothing here hardcodes it.
--   4. Wired into the daily run: after both the influence and netnew
--      jobs finish (same invocation), repoint_sourced_program() runs
--      automatically for that day's snapshot_date. A run missing either
--      job (e.g. `--only netnew`) skips this step rather than guessing.
--   5. sync_to_mktg.py --backfill-sourced-program (new flag): runs
--      repoint_sourced_program() for every existing snapshot_date,
--      oldest first, honoring the same 2026-09-15 cutoff and no-data
--      skips. This is the one-time backfill - see the down migration
--      for what a revert does NOT restore.
--   6. mktg.f_sourced_by_program (this migration, PASTE 1 below): its
--      `programs` CTE changes from a hardcoded VALUES list to
--      `select distinct program from config_campaign_type_program`,
--      ordered by name. Nothing else about the function changes -
--      row_type discipline, the reconciling '(multi)' row, the
--      not_measured mechanism via config_settings.unmeasured_programs,
--      all identical. mktg.v_sourced_by_program is unchanged (it is
--      still `select * from f_sourced_by_program(true, null)` - one
--      body, so it picks up this change automatically).
--
-- WHAT DOES NOT CHANGE
--   mktg.v_deal_program, mktg.f_influenced_by_program,
--   mktg.v_deal_touch_summary, mktg.config_campaign_type_program,
--   generate_report.CAMPAIGN_TYPE_PROGRAM - all untouched, all already
--   correct. mktg.f_marketing_sourced_by_program (2026-09-16) needs NO
--   change - it already reads snap_sourced_deal.program, which this
--   migration makes correct at the source instead of query-time.
--   config_program_keywords / generate_netnew_report.PROGRAM_KEYWORDS
--   are left in place (harmless, no longer read by anything in
--   mktg) - not dropped, same "leave it, drop by hand only if certain"
--   convention as config_campaign_type_program was left in the
--   2026-09-15 down migration.
--
-- ORDER OF OPERATIONS
--   1. Run PASTE 1 below in the Supabase SQL editor (f_sourced_by_program
--      only - no table/column changes in this migration).
--   2. Run `python sync_to_mktg.py --backfill-sourced-program` to
--      rewrite every eligible existing snapshot_date's
--      program/is_single_program from v_deal_program. Dates before
--      2026-09-15 are reported as skipped, not rewritten.
--   3. The next daily run repoints the new snapshot_date automatically -
--      no further manual steps.
--
-- No explicit BEGIN. A single CREATE OR REPLACE FUNCTION statement, so
-- there is nothing for a partial failure to leave half-applied.
-- =====================================================================


-- ============================== PASTE 1 ==============================

CREATE OR REPLACE FUNCTION mktg.f_sourced_by_program(include_amazon boolean DEFAULT true, close_year integer DEFAULT NULL::integer)
 RETURNS TABLE(snapshot_date date, row_type text, program text, measurement text, sourced_deals bigint, sourced_pipeline numeric, sourced_won numeric, won_deals bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with scope as (
        select *
        from snap_sourced_deal
        where (include_amazon or not is_amazon)
          and (close_year is null or extract(year from close_date) = close_year)
    ),
    days as (
        select distinct snapshot_date from snap_sourced_deal
    ),
    programs as (
        select program,
               row_number() over (order by program) as sort_order
        from (select distinct program from config_campaign_type_program) d
    ),
    unmeasured as (
        select coalesce(
                 (select array(select trim(x)
                                 from unnest(string_to_array(value, ',')) as x)
                    from config_settings
                   where key = 'unmeasured_programs'),
                 '{}'::text[]) as names
    ),
    program_rows as (
        select d.snapshot_date,
               'program'::text as row_type,
               p.program,
               case when p.program = any(u.names)
                    then 'not_measured' else 'measured' end as measurement,
               count(s.deal_id)                                              as sourced_deals,
               coalesce(sum(s.amount_home), 0)                               as sourced_pipeline,
               coalesce(sum(s.amount_home) filter (where s.is_closed_won), 0) as sourced_won,
               count(s.deal_id) filter (where s.is_closed_won)               as won_deals,
               p.sort_order
        from days d
        cross join programs p
        cross join unmeasured u
        left join scope s
               on s.snapshot_date = d.snapshot_date
              and s.is_single_program
              and s.program = p.program
        group by d.snapshot_date, p.program, p.sort_order, u.names
    ),
    reconciling_rows as (
        select d.snapshot_date,
               'reconciling'::text,
               '(multi)'::text,
               'measured'::text,
               count(s.deal_id),
               coalesce(sum(s.amount_home), 0),
               coalesce(sum(s.amount_home) filter (where s.is_closed_won), 0),
               count(s.deal_id) filter (where s.is_closed_won),
               (select max(sort_order) + 1 from programs)
        from days d
        left join scope s
               on s.snapshot_date = d.snapshot_date
              and s.program = '(multi)'
        group by d.snapshot_date
    )
    select snapshot_date, row_type, program, measurement,
           sourced_deals, sourced_pipeline, sourced_won, won_deals
    from (select * from program_rows
          union all
          select * from reconciling_rows) x
    order by snapshot_date, sort_order;
$function$;
