-- =====================================================================
-- DOWN 3/3: restore the prior program-bucket objects
-- =====================================================================
-- Reverses 2026-09-02_program_row_type.sql.
--
-- Definitions below are copied verbatim from docs/schema.sql as captured
-- on 2026-09-02, including the grants that DROP discarded.
--
-- Fully reversible. No data is touched, only definitions plus one
-- config_settings row.
--
-- After running this, /overview goes back to what it showed before:
-- Content & Technology, Events, and the two dead (multi) and
-- (unclassified) rows returning 0 deals and NULL dollars. If the Lovable
-- change is already deployed it stays safe, because its filter keeps rows
-- where row_type is absent as well as rows where it equals 'program'.
-- =====================================================================


-- ============================== PASTE 1 ==============================

-- 1. Prior f_sourced_by_program. Return type differs from what is
--    deployed, so drop first.
drop function if exists mktg.f_sourced_by_program(boolean, integer);

create function mktg.f_sourced_by_program(
    include_amazon boolean default true,
    close_year     integer default null
)
returns table (
    snapshot_date    date,
    program          text,
    sourced_deals    bigint,
    sourced_pipeline numeric,
    sourced_won      numeric,
    won_deals        bigint
)
language sql
stable
set search_path to 'mktg'
as $function$
    select
        snapshot_date,
        coalesce(program, '(unclassified)'),
        count(*) filter (where is_single_program),
        sum(amount_home) filter (where is_single_program),
        sum(amount_home) filter (where is_single_program and is_closed_won),
        count(*) filter (where is_single_program and is_closed_won)
    from snap_sourced_deal
    where (include_amazon or not is_amazon)
      and (close_year is null or extract(year from close_date) = close_year)
    group by snapshot_date, coalesce(program, '(unclassified)');
$function$;


-- 2. Prior v_sourced_by_program, its own body again rather than a call
--    into the function.
drop view if exists mktg.v_sourced_by_program;

create view mktg.v_sourced_by_program as
 SELECT snapshot_date,
    COALESCE(program, '(unclassified)'::text) AS program,
    count(*) FILTER (WHERE is_single_program) AS sourced_deals,
    sum(amount_home) FILTER (WHERE is_single_program) AS sourced_pipeline,
    sum(amount_home) FILTER (WHERE is_single_program AND is_closed_won) AS sourced_won,
    count(*) FILTER (WHERE is_single_program AND is_closed_won) AS won_deals
   FROM mktg.snap_sourced_deal
  GROUP BY snapshot_date, (COALESCE(program, '(unclassified)'::text));


-- 3. Prior f_pipeline_model, without the row_type filter. Required: the
--    restored f_sourced_by_program has no row_type column, so leaving the
--    filter in place would make this function fail outright.
create or replace function mktg.f_pipeline_model(
    include_amazon boolean default true,
    close_year     integer default null
)
returns table (
    snapshot_date                  date,
    sourced_pipeline               numeric,
    target_2027                    numeric,
    assigned_wr                    numeric,
    qualified_pipeline_needed_2027 numeric,
    sourced_share_of_need          numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
    with cfg as (
        select
          max(case when key='target_2027' then value::numeric end)            as target_2027,
          max(case when key='assigned_win_rate_2027' then value::numeric end) as assigned_wr
        from config_settings
    ),
    sourced as (
        select snapshot_date, sum(sourced_pipeline) as sourced_pipeline
        from f_sourced_by_program(include_amazon, close_year) group by snapshot_date
    )
    select
        s.snapshot_date, s.sourced_pipeline, c.target_2027, c.assigned_wr,
        (c.target_2027 / nullif(c.assigned_wr,0)),
        s.sourced_pipeline / nullif(c.target_2027 / nullif(c.assigned_wr,0), 0)
    from sourced s cross join cfg c;
$function$;


-- 4. Remove the config row the up migration added. Harmless if left, but
--    it describes behaviour that no longer exists.
delete from mktg.config_settings where key = 'unmeasured_programs';


-- 5. Re-grant.
grant select  on mktg.v_sourced_by_program                            to authenticated;
grant execute on function mktg.f_sourced_by_program(boolean, integer) to authenticated;
grant execute on function mktg.f_pipeline_model(boolean, integer)     to authenticated;

-- ============================ END PASTE 1 ============================


-- ============================== PASTE 2 ==============================
-- Verification. Run separately, after PASTE 1.

-- (a) expect exactly 4 rows, no row_type or measurement column,
--     (multi) and (unclassified) back as dead rows with NULL dollars:
--       (multi)               0  NULL        NULL       0
--       (unclassified)        0  NULL        NULL       0
--       Content & Technology  134  8646483.89  668815.29  49
--       Events                 14   591421.09   66210.41   4
select program, sourced_deals, sourced_pipeline, sourced_won, won_deals
  from mktg.f_sourced_by_program(true, null)
 order by program;

-- (b) expect exactly one row: 9237904.98 | 0.1847580996
select sourced_pipeline, sourced_share_of_need
  from mktg.f_pipeline_model(true, null);

-- (c) expect exactly one row: 5003533.00 | 0.10007066
select sourced_pipeline, sourced_share_of_need
  from mktg.f_pipeline_model(true, 2027);

-- (d) expect exactly one row, one column, value 0
select count(*) as should_be_zero
  from mktg.config_settings
 where key = 'unmeasured_programs';

-- ============================ END PASTE 2 ============================
