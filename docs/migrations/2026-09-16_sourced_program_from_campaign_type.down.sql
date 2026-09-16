-- =====================================================================
-- DOWN: restore f_sourced_by_program's hardcoded 5-bucket program list
-- =====================================================================
-- Reverts 2026-09-16_sourced_program_from_campaign_type.sql.
--
-- Run this BEFORE reverting sync_to_mktg.py's rows_sourced_deal /
-- repoint_sourced_program / backfill_sourced_program changes, same
-- discipline as every other migration pair here.
--
-- WHAT THIS DOES NOT UNDO
--   snap_sourced_deal.program / is_single_program values already
--   rewritten by repoint_sourced_program() / --backfill-sourced-program
--   are NOT reverted to their old keyword-based values by this file -
--   that classification was never stored anywhere once overwritten, so
--   there is nothing to restore it from. Reverting only stops FUTURE
--   writes from using the new mechanism; already-repointed snapshot_date
--   rows keep whatever v_deal_program-derived value they were given.
--   If you need the old classification back, you would need to re-run
--   generate_netnew_report.build_dataset() for each affected date and
--   rewrite program/is_single_program from its output - not provided
--   here, since nothing about this revert implies that is wanted.
-- =====================================================================

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
