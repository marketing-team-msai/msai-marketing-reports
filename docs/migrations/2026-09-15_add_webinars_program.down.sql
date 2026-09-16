-- =====================================================================
-- DOWN: remove Webinars as a program bucket
-- =====================================================================
-- Reverts 2026-09-15_add_webinars_program.sql.
--
-- Run this BEFORE reverting PROGRAM_KEYWORDS / running --sync-keywords
-- back to a state without Webinars, for the same reason the up-migration
-- warns about running its two steps in order: if config_program_keywords
-- no longer has "webinar" but these functions still expect a Webinars row,
-- that row simply shows a permanent genuine zero, which is harmless but
-- pointless. Reverting these functions first, then --sync-keywords, keeps
-- the same discipline.
--
-- Any snap_sourced_deal rows already written with program = 'Webinars'
-- are NOT touched by this - they keep reading as 'Webinars' in
-- f_sourced_by_program (which will show it as an unmeasured/unknown extra
-- program row falling outside the reverted 4-row `programs` VALUES list,
-- i.e. those deals disappear from every sourced-pipeline total, same
-- failure mode the up-migration's "order of operations" note describes in
-- reverse). If Webinars is ever turned off after real snapshots have used
-- it, re-add it to `programs` as a permanently unmeasured/zero bucket
-- instead of dropping it outright, or accept that dollars will vanish
-- from historical totals for however many snapshot_dates used it.
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
               ('PR & Brand',           4)
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
               ('PR & Brand',           4)
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
