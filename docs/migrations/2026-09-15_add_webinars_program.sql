-- =====================================================================
-- UP: add Webinars as a fifth program bucket
-- =====================================================================
-- Down version: 2026-09-15_add_webinars_program.down.sql
--
-- WHY
--   Webinar campaigns have always existed in the Campaign Influence lists
--   but had no keyword of their own in PROGRAM_KEYWORDS
--   (generate_netnew_report.py), so classify_program() fell through to the
--   Content & Technology catch-all for every one of them. This migration
--   adds Webinars as its own program, keyed off the "webinar" keyword,
--   so it can be reported on separately instead of being buried inside
--   Content & Technology.
--
-- WHAT THIS MIGRATION DOES, AND DOES NOT DO
--   It adds a fifth row to the fixed `programs` dimension in
--   f_sourced_by_program and f_influenced_by_program - the two places
--   that enumerate "the programs" as a VALUES list so every program shows
--   a genuine-zero row rather than being absent (same shape as Advertising
--   and PR & Brand already get). It does NOT change v_deal_program,
--   v_sourced_by_program, v_influenced_by_program, f_influence_by_campaign,
--   f_influenced_pipeline, or f_influenced_by_combination - those already
--   read the program value generically (from config_program_keywords or
--   from v_deal_program) and need no schema change to carry a fifth value.
--
--   Same signature as before on both functions (include_amazon/close_year
--   unchanged), so CREATE OR REPLACE is safe here and keeps existing
--   grants - unlike the argument-signature-change case in CLAUDE.md, this
--   does not need a DROP first.
--
-- ORDER OF OPERATIONS - READ BEFORE RUNNING
--   1. Run PASTE 1 below in the Supabase SQL editor.
--   2. Run `python sync_to_mktg.py --sync-keywords` (or wait for the next
--      daily workflow run) to reconcile mktg.config_program_keywords to
--      PROGRAM_KEYWORDS, which now includes ("Webinars", 4, ("webinar",)).
--   Do it in THIS order. If step 2 ran before step 1, v_deal_program would
--   already be classifying some deals as program = 'Webinars' while
--   f_sourced_by_program's `programs` VALUES list still only had four
--   rows - those deals would join to nothing in program_rows and simply
--   vanish from every sourced-pipeline total until this migration landed,
--   rather than showing up as a genuine zero.
--
-- TWO-SPEED RETROACTIVITY - SEE generate_netnew_report.py AND CLAUDE.md
--   f_influenced_by_program / f_influenced_pipeline / f_influenced_by_combination
--   read v_deal_program, which classifies from config_program_keywords at
--   QUERY time. The moment step 2 above runs, every historical
--   snapshot_date's influenced-pipeline-by-program numbers move: some
--   deals move out of Content & Technology and into Webinars.
--
--   f_sourced_by_program reads mktg.snap_sourced_deal.program /
--   .is_single_program, which generate_netnew_report.py computes in Python
--   and freezes into the row at ETL write time. Already-written
--   snapshot_date rows are NOT rewritten by step 2 - sourced-by-program
--   only starts showing Webinars from the next daily run's new
--   snapshot_date forward. This was a deliberate choice (see CLAUDE.md
--   "Webinars program"): a backfill of historical snap_sourced_deal rows
--   was considered and rejected as more disruptive than it's worth.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres, so if any statement fails the whole paste
-- rolls back on its own.
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
    programs (program, sort_order) as (
        values ('Content & Technology', 1),
               ('Events',               2),
               ('Advertising',          3),
               ('PR & Brand',           4),
               ('Webinars',             5)
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
               9
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

CREATE OR REPLACE FUNCTION mktg.f_influenced_by_program(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, program text, measurement text, deals bigint, pipeline numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with days as (
        select distinct snapshot_date from snap_sourced_deal
    ),
    programs (program, sort_order) as (
        values ('Content & Technology', 1),
               ('Events',               2),
               ('Advertising',          3),
               ('PR & Brand',           4),
               ('Webinars',             5)
    ),
    unmeasured as (
        select coalesce(
                 (select array(select trim(x)
                                 from unnest(string_to_array(value, ',')) as x)
                    from config_settings
                   where key = 'unmeasured_programs'),
                 '{}'::text[]) as names
    ),
    scope as (
        select p.snapshot_date, p.deal_id, p.program,
               coalesce(d.amount_home, 0) as amount_home
        from v_deal_program p
        join snap_sourced_deal d
          on d.snapshot_date = p.snapshot_date
         and d.deal_id       = p.deal_id
        where include_amazon or not coalesce(d.is_amazon, false)
    )
    select dy.snapshot_date,
           pr.program,
           case when pr.program = any(u.names)
                then 'not_measured' else 'measured' end,
           count(s.deal_id),
           coalesce(sum(s.amount_home), 0)
    from days dy
    cross join programs pr
    cross join unmeasured u
    left join scope s
           on s.snapshot_date = dy.snapshot_date
          and s.program       = pr.program
    group by dy.snapshot_date, pr.program, pr.sort_order, u.names
    order by dy.snapshot_date, pr.sort_order;
$function$;


-- ============================== PASTE 2 ==============================
-- Verification. Run each and compare. Run these AFTER
-- `python sync_to_mktg.py --sync-keywords` (step 2 above) - before that,
-- Webinars will show a genuine 0 / $0.00 in f_sourced_by_program (correct:
-- no snapshot has been written with that classification yet) and will not
-- appear at all in f_influenced_by_program's live numbers (correct: no
-- keyword to match on yet). Expected values below are illustrative shape,
-- not fixed figures - re-derive against the live snapshot_date you test.

-- 2.1  f_sourced_by_program now returns 6 rows per snapshot_date (5
--      program rows + 1 reconciling), not 5. Webinars appears with
--      sourced_deals = 0 until the next daily run writes a new
--      snapshot_date under the updated PROGRAM_KEYWORDS.
select row_type, program, measurement, sourced_deals, sourced_pipeline
from mktg.f_sourced_by_program(true, null)
where snapshot_date = (select max(snapshot_date) from mktg.snap_sourced_deal)
order by row_type, program;

-- 2.2  f_influenced_by_program now returns 5 rows per snapshot_date, not
--      4. After --sync-keywords has run, Webinars should show a nonzero
--      deals/pipeline figure if any Campaign Influence list name contains
--      "webinar", and Content & Technology's total should have dropped by
--      the same amount it had before.
select program, measurement, deals, pipeline
from mktg.f_influenced_by_program(true)
where snapshot_date = (select max(snapshot_date) from mktg.snap_sourced_deal)
order by program;

-- 2.3  Sanity check that nothing vanished: total influenced deals/pipeline
--      (f_influenced_pipeline row_type = 'total') must be unchanged by
--      this migration - only the by-program breakdown shifts.
select row_type, deals, pipeline
from mktg.f_influenced_pipeline(true)
where snapshot_date = (select max(snapshot_date) from mktg.snap_sourced_deal)
  and row_type = 'total';
