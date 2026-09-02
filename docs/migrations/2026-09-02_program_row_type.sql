-- =====================================================================
-- mktg: program-bucket rework
-- =====================================================================
-- NOT APPLIED.
--
-- BLOCKED ON A FRONTEND CHANGE. Read this before scheduling it.
--
--   /overview calls f_sourced_by_program(include_amazon) for the Sourced
--   Pipeline tile AND the by-program bar chart. This migration adds a
--   (multi) row carrying 42 deals / $2,452,255.97 to that function's
--   output. A tile that sums the rows it gets back jumps from
--   $9,237,904.98 to $11,690,160.95, and the bar chart grows a $2,452,256
--   "(multi)" bar plus two new zero bars.
--
--   That is the same trap this migration fixes inside f_pipeline_model,
--   arriving through the frontend instead. /overview must filter
--   row_type = 'program' on both the tile and the chart BEFORE this is
--   applied. Dashboard first, then migrate.
--
-- What changes
--   1. (unclassified) is dropped. Those 671 rows are uninfluenced deals,
--      not unclassified ones, and exposing them puts $37,463,872.93 of
--      non-marketing pipeline inside a marketing program report.
--   2. All four programs are emitted from a fixed list, zero-filled, so
--      Advertising and PR & Brand stop vanishing from the output.
--   3. Multi-program deals return as a single reconciling row, tagged
--      row_type = 'reconciling'. The four program rows are 'program'.
--   4. f_pipeline_model filters row_type = 'program', so its numbers do
--      not move.
--
-- Two grants traps this migration has to handle
--   - Changing a function's RETURN TYPE means create-or-replace will not
--     replace it. It creates a second overload and Postgres then throws
--     "could not choose the best candidate function". Hence drop first.
--   - DROP discards privileges. authenticated currently has SELECT on
--     every mktg table and view, so the grants are re-issued below. Miss
--     them and the dashboard 403s on its next read.
--
-- Run inside an explicit transaction. Apply, run the verification block,
-- and only commit if every figure matches. If one misses, roll back and
-- report rather than adjusting the SQL to match the output.
-- =====================================================================

begin;


-- ---------------------------------------------------------------------
-- 1. Which programs have no measurement path at all
-- ---------------------------------------------------------------------
-- Advertising reads 0 because paid touches are not captured, not because
-- paid produced nothing: 8 of its 12 Campaign Influence lists are empty,
-- and its only deal-touching campaign touches one deal that sits outside
-- the Net New pipeline. A bare $0.00 next to a media budget line reads as
-- "paid produces no pipeline", which is not what the data says.
--
-- Config-driven rather than hardcoded in the function, so this is a row
-- to delete once the snap_ad_source leg is built, not a migration.
insert into mktg.config_settings (key, value, value_type, description)
values ('unmeasured_programs', 'Advertising', 'csv',
        'Programs whose zero means "not measured" rather than "measured and zero". Rendered as a dash, never $0.00. Remove a program here once its source lands.')
on conflict (key) do update
   set value = excluded.value,
       description = excluded.description,
       updated_at = now();


-- ---------------------------------------------------------------------
-- 2. f_sourced_by_program
-- ---------------------------------------------------------------------
-- No display strings are returned. row_type, program and the numbers go
-- back; the frontend composes the reconciling row's caption, which for
-- the current snapshot reads "Multi-program deals, not credited to any
-- single program (42, $2,452,255.97)".
drop function if exists mktg.f_sourced_by_program(boolean, integer);

create function mktg.f_sourced_by_program(
    include_amazon boolean default true,
    close_year     integer default null
)
returns table (
    snapshot_date    date,
    row_type         text,
    program          text,
    measurement      text,
    sourced_deals    bigint,
    sourced_pipeline numeric,
    sourced_won      numeric,
    won_deals        bigint
)
language sql
stable
set search_path to 'mktg'
as $function$
    with scope as (
        select *
        from snap_sourced_deal
        where (include_amazon or not is_amazon)
          and (close_year is null or extract(year from close_date) = close_year)
    ),
    -- Days come from the UNFILTERED table on purpose. A snapshot whose
    -- deals are all filtered out still has to report four zero rows
    -- rather than disappearing from the series.
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
               -- count(s.deal_id), not count(*): with the zero-fill left
               -- join count(*) returns 1 for a program with no deals, so
               -- Advertising and PR & Brand would read 1 instead of 0.
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
    -- Below the line. Counted, never credited to a program.
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


-- ---------------------------------------------------------------------
-- 3. v_sourced_by_program
-- ---------------------------------------------------------------------
-- Nothing reads this view: /overview uses the RPC. So the column-list
-- change is safe, and defining it as the function's default-argument
-- call means there is only one body. Two objects answering the same
-- question from two separate bodies is exactly how v_influence_headline
-- drifted from f_influence_headline.
drop view if exists mktg.v_sourced_by_program;

create view mktg.v_sourced_by_program as
select * from mktg.f_sourced_by_program(true, null);


-- ---------------------------------------------------------------------
-- 4. f_pipeline_model
-- ---------------------------------------------------------------------
-- Signature and return type are unchanged, so create-or-replace is safe
-- here and the existing privileges survive.
--
-- The filter is the entire purpose of row_type. Without it this function
-- silently absorbs the reconciling row and sourced pipeline moves from
-- $9,237,904.98 to $11,690,160.95 on the close_year = null call.
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
        from f_sourced_by_program(include_amazon, close_year)
        where row_type = 'program'
        group by snapshot_date
    )
    select
        s.snapshot_date, s.sourced_pipeline, c.target_2027, c.assigned_wr,
        (c.target_2027 / nullif(c.assigned_wr,0)),
        s.sourced_pipeline / nullif(c.target_2027 / nullif(c.assigned_wr,0), 0)
    from sourced s cross join cfg c;
$function$;


-- ---------------------------------------------------------------------
-- 5. Re-grant what the drops discarded
-- ---------------------------------------------------------------------
grant select  on mktg.v_sourced_by_program                            to authenticated;
grant execute on function mktg.f_sourced_by_program(boolean, integer) to authenticated;
grant execute on function mktg.f_pipeline_model(boolean, integer)     to authenticated;


-- =====================================================================
-- VERIFICATION. Run all four before deciding. Expected values are for
-- snapshot 2026-09-02. Any miss means rollback, not an edit to the SQL.
-- =====================================================================

-- (a) shape and per-program figures
select row_type, program, measurement, sourced_deals, sourced_pipeline,
       sourced_won, won_deals
  from mktg.f_sourced_by_program(true, null);
--   program      Content & Technology  measured       134  8646483.89  668815.29  49
--   program      Events                measured        14   591421.09   66210.41   4
--   program      Advertising           not_measured     0        0.00       0.00   0
--   program      PR & Brand            measured         0        0.00       0.00   0
--   reconciling  (multi)               measured        42  2452255.97   41942.04   5
--   5 rows, no (unclassified)

-- (b) the headline is unchanged above the line
select sum(sourced_deals) as deals, sum(sourced_pipeline) as pipeline
  from mktg.f_sourced_by_program(true, null)
 where row_type = 'program';
--   148, 9237904.98

-- (c) f_pipeline_model, close_year null
select sourced_pipeline, sourced_share_of_need
  from mktg.f_pipeline_model(true, null);
--   9237904.98, 0.1847580996

-- (d) f_pipeline_model, close_year 2027. THIS is the call /overview's
--     Progress to 2027 Target tile actually makes, and its numbers are
--     not the same as (c). Both have to hold.
select sourced_pipeline, sourced_share_of_need
  from mktg.f_pipeline_model(true, 2027);
--   5003533.00, 0.10007066

-- commit;
-- rollback;
