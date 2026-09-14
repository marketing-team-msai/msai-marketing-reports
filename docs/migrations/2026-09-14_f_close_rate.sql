-- =====================================================================
-- UP: f_close_rate, and v_close_rate onto the same body
-- =====================================================================
-- Down version: 2026-09-14_f_close_rate.down.sql
--
-- Replaces the hard-coded close-rate assumptions in
-- generate_netnew_report.py MODEL (close_rate_amazon 0.70,
-- close_rate_non_amazon 0.30) with measured rates. Those constants came
-- from the July 2026 ELT offsite deck and nothing has recomputed them
-- since. They stay in the module for the workbook's planning maths; this
-- function is the measured counterpart, not a replacement for the plan.
--
-- WHY A FUNCTION AND NOT AN ETL LEG
--   mktg.snap_close_rate exists and holds 0 rows. It is segment-grain,
--   which makes it an aggregate living in a snap_ table, against the rule
--   sync_to_mktg.py states in its own docstring: "The snap_* tables are
--   entity-grain detail, not aggregates. Roll-ups belong to the views and
--   functions." Every input is already in snap_sourced_deal at deal grain
--   - is_closed, is_closed_won, is_amazon, vertical, amount_home - so a
--   function needs no new pull, no daily write, and cannot drift from the
--   deal data. It also backfills every snapshot already written the
--   moment it lands, which an ETL leg could not.
--
--   snap_close_rate is KEPT, not dropped. It is now superseded: nothing
--   writes it, nothing reads it, and this function is where close rate
--   lives. Decide separately whether to drop it.
--
-- WHAT THE POPULATION ACTUALLY IS - READ THIS BEFORE LABELLING ANYTHING
--   Verified live 2026-09-14 against snapshot 2026-09-14.
--
--   It is NOT all won and lost opportunities in the portal. The Net New
--   ETL filters pipeline EQ 813739955 (generate_netnew_report.py:240), so
--   the population is one pipeline: all 436 rows in snap_sourced_deal
--   carry pipeline = 'Net New Pipeline'. Any other pipeline is absent
--   entirely. These rates are that pipeline's rates and must be labelled
--   as such.
--
--   It is NOT marketing-sourced only, which is the more likely misread
--   given the table's name. snap_sourced_deal holds the FULL Net New
--   population: of 436 deals, 322 are uninfluenced, 71 are single-program
--   sourced and 43 are multi-program. So the denominator is every deal in
--   the pipeline, not a marketing subset, and the rates are commercial
--   rates rather than marketing rates. Do not caption them "marketing
--   sourced win rate".
--
--   Closed splits exactly: 272 closed = 205 Closed Won + 67 Closed Lost,
--   with no third terminal stage and no null is_closed_won. The remaining
--   164 sit in six genuinely mid-funnel stages. So won + lost = closed
--   holds, and nothing leaks out of the denominator.
--
--   The window is the create-date window, not a close-date window. These
--   are deals CREATED on or after config_settings.window_anchor_netnew
--   that have since closed. A deal created in 2025 that closed in 2026 is
--   not here. That makes this number a cohort rate, NOT comparable to the
--   offsite 0.70 / 0.30, which came from a wider book (425 won / $8.52M
--   against 205 won / $5.89M here). Do not present the two side by side
--   as though one updates the other.
--
-- DEAL RATE AND DOLLAR RATE ARE BOTH RETURNED, SEPARATELY LABELLED
--   They diverge hard and the divergence is the finding:
--
--     Amazon        deal 0.9568   dollar 0.7186
--     non-Amazon    deal 0.4545   dollar 0.4358
--     Dist & Whse   deal 0.9290   dollar 0.6890
--
--   Amazon wins nearly every deal but loses the larger ones. Note that
--   its dollar rate, 0.7186, lands almost exactly on the offsite's 0.70
--   assumption while its deal rate is 0.96 - which is the best available
--   evidence that the offsite constant was dollar-weighted. non-Amazon is
--   above its 0.30 assumption on either basis. Neither observation is
--   proof, because of the population mismatch above.
--
--   deal_win_rate   = won_count / closed_deals
--   dollar_win_rate = won_amount / (won_amount + lost_amount)
--
--   Never call either one "close_rate" unqualified. The column that used
--   to carry that name is on the superseded table.
--
-- THE MINIMUM-N FLOOR
--   A vertical with one closed deal produces a rate of 1.000 or 0.000 and
--   is noise. Segments below config_settings.close_rate_min_closed get
--   measurement = 'below_threshold' and NULL for both rates, while still
--   reporting their counts and amounts. Render a dash, never 0%.
--
--   'below_threshold' is deliberately NOT the string 'not_measured' that
--   f_sourced_by_program uses for Advertising. That one means "no source
--   is captured". This one means "captured, but too few to mean
--   anything". Same dash on screen, different reasons, so they get
--   different words.
--
-- SUMMING ACROSS SEGMENT TYPES TRIPLE COUNTS
--   Same trap as f_sourced_by_program's row_type. Every closed deal
--   appears three times: once under segment_type 'all', once under
--   'amazon', once under 'vertical'. 18 rows per snapshot at present, and
--   sum(won_count) across all of them is 615, not 205. Anything reading
--   this function must filter on segment_type, exactly as the /overview
--   tile filters on row_type.
--
-- AND IT RETURNS EVERY SNAPSHOT
--   Like every other f_* here. 18 rows per snapshot, so it clears the
--   PostgREST 1000-row cap for about 55 days and then starts truncating
--   the NEWEST snapshot first, silently. Filter server-side:
--   .rpc("f_close_rate", args).eq("snapshot_date", d)
--
-- Paste PASTE 1 into the Supabase SQL editor and Run. Then paste PASTE 2
-- and Run, and compare against the expected output beside each query. Do
-- not edit this file to match what you get.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres, so if any statement fails the whole paste
-- rolls back on its own.
-- =====================================================================


-- ============================== PASTE 1 ==============================

-- The floor, and the population label the dashboard should render.
--
-- close_rate_population deliberately does NOT restate the window date.
-- window_anchor_netnew already holds it and the dashboard already reads
-- it live; a second copy here is exactly the two-sources-of-truth bug
-- that put a false date under every caption on this project once
-- already. Compose the caption from the two rows.
insert into mktg.config_settings (key, value, value_type, description)
values
  ('close_rate_min_closed', '20', 'number',
   'f_close_rate: a segment with fewer closed deals than this reports its '
   'counts but NULL rates, measurement = below_threshold. Render a dash, '
   'never 0%. Guards against a vertical with n=1 showing 100%.'),
  ('close_rate_population', 'Net New Pipeline (HubSpot id 813739955). Every '
   'deal in that pipeline, not only marketing-sourced ones. Created-date '
   'cohort, so not comparable to a close-date win rate.', 'text',
   'f_close_rate: what the win rates are computed over. Compose the caption '
   'with window_anchor_netnew for the date; do not hard-code either.')
on conflict (key) do update
  set value = excluded.value,
      value_type = excluded.value_type,
      description = excluded.description,
      updated_at = now();


-- CLAUDE.md: "create or replace function does not replace a function when
-- the argument signature changes. It creates a second overload." Nothing
-- of this name exists yet, but the drop keeps a re-run of this file
-- honest.
drop function if exists mktg.f_close_rate(integer);

create or replace function mktg.f_close_rate(close_year integer default null)
returns table (
    snapshot_date   date,
    segment_type    text,
    segment_value   text,
    measurement     text,
    closed_deals    bigint,
    won_count       bigint,
    lost_count      bigint,
    won_amount      numeric,
    lost_amount     numeric,
    deal_win_rate   numeric,
    dollar_win_rate numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
    -- Closed deals only. is_closed is nullable on the table, and `where
    -- is_closed` drops nulls, which is what we want: unknown is not
    -- closed. is_closed_won and amount_home are coalesced rather than
    -- trusted, so a future null cannot vanish from both won and lost
    -- while still counting in closed_deals and quietly breaking
    -- won + lost = closed.
    with scope as (
        select snapshot_date,
               coalesce(is_closed_won, false) as is_won,
               coalesce(is_amazon, false)     as is_amazon,
               coalesce(vertical, 'Unknown')  as vertical,
               coalesce(amount_home, 0)       as amount_home
        from snap_sourced_deal
        where is_closed
          and (close_year is null
               or extract(year from close_date) = close_year)
    ),
    floor_n as (
        select coalesce(
                 (select value::integer
                    from config_settings
                   where key = 'close_rate_min_closed'),
                 20) as min_closed
    ),
    -- One row per deal per segment type. A deal is counted three times
    -- across the three types, once within each. See the triple-count
    -- note in the header.
    segmented as (
        select snapshot_date, 'all'::text as segment_type,
               'All Net New'::text as segment_value, 1 as sort_order,
               is_won, amount_home
        from scope
        union all
        select snapshot_date, 'amazon',
               case when is_amazon then 'Amazon' else 'non-Amazon' end, 2,
               is_won, amount_home
        from scope
        union all
        select snapshot_date, 'vertical', vertical, 3,
               is_won, amount_home
        from scope
    ),
    agg as (
        select snapshot_date, segment_type, segment_value, sort_order,
               count(*)                                                  as closed_deals,
               count(*) filter (where is_won)                            as won_count,
               count(*) filter (where not is_won)                        as lost_count,
               coalesce(sum(amount_home) filter (where is_won), 0)       as won_amount,
               coalesce(sum(amount_home) filter (where not is_won), 0)   as lost_amount
        from segmented
        group by snapshot_date, segment_type, segment_value, sort_order
    )
    select a.snapshot_date,
           a.segment_type,
           a.segment_value,
           case when a.closed_deals >= f.min_closed
                then 'measured' else 'below_threshold' end,
           a.closed_deals,
           a.won_count,
           a.lost_count,
           a.won_amount,
           a.lost_amount,
           case when a.closed_deals >= f.min_closed and a.closed_deals > 0
                then round(a.won_count::numeric / a.closed_deals, 4) end,
           case when a.closed_deals >= f.min_closed
                     and (a.won_amount + a.lost_amount) > 0
                then round(a.won_amount / (a.won_amount + a.lost_amount), 4) end
    from agg a
    cross join floor_n f
    order by a.snapshot_date, a.sort_order, a.segment_value;
$function$;


-- One body, so the two cannot drift. Same rule as v_sourced_by_program.
create or replace view mktg.v_close_rate as
select snapshot_date, segment_type, segment_value, measurement,
       closed_deals, won_count, lost_count, won_amount, lost_amount,
       deal_win_rate, dollar_win_rate
from mktg.f_close_rate(null);


grant select on mktg.v_close_rate to authenticated;
grant execute on function mktg.f_close_rate(integer) to authenticated;


comment on function mktg.f_close_rate(integer) is
  'Won/lost counts and amounts with separately labelled deal_win_rate and '
  'dollar_win_rate, over the Net New Pipeline create-date cohort in '
  'snap_sourced_deal - every deal in that pipeline, not only '
  'marketing-sourced. Returns every snapshot_date: filter server-side. '
  'Segments triple count across segment_type: filter that too. Supersedes '
  'mktg.snap_close_rate, which is empty and unwritten.';


-- ============================== PASTE 2 ==============================
-- Verification. Run each and compare. Expected values are the live
-- figures for snapshot 2026-09-14 and will move with CRM activity on any
-- later snapshot - re-derive rather than assuming a mismatch is a bug.

-- 2.1  The three headline segments.
--
-- expected, snapshot 2026-09-14:
--   all     All Net New   measured  272  205  67  5886665.20  3524703.06  0.7537  0.6255
--   amazon  Amazon        measured  162  155   7  4536021.93  1776114.00  0.9568  0.7186
--   amazon  non-Amazon    measured  110   50  60  1350643.27  1748589.06  0.4545  0.4358
select segment_type, segment_value, measurement, closed_deals, won_count,
       lost_count, won_amount, lost_amount, deal_win_rate, dollar_win_rate
from mktg.f_close_rate(null)
where snapshot_date = '2026-09-14'
  and segment_type in ('all', 'amazon')
order by segment_type, segment_value;

-- 2.2  Verticals, and the floor doing its job.
--
-- expected: 15 rows, of which exactly TWO are measured -
--   Distribution & Warehousing  measured  169  157  12  0.9290  0.6890
--   Unknown                     measured   70   30  40  0.4286  0.5121
-- every other vertical is below_threshold with NULL in both rate columns
-- and its counts still populated. Largest suppressed segment is Other at
-- 11 closed. Aerospace & Defense, Automotive, Consulting, Medical,
-- Power Generation & Utilities and Department Stores each have 1.
select segment_value, measurement, closed_deals, won_count, lost_count,
       deal_win_rate, dollar_win_rate
from mktg.f_close_rate(null)
where snapshot_date = '2026-09-14'
  and segment_type = 'vertical'
order by closed_deals desc, segment_value;

-- 2.3  won + lost = closed, on every row. Nothing leaks.
--
-- expected: 0 rows
select snapshot_date, segment_type, segment_value,
       closed_deals, won_count, lost_count
from mktg.f_close_rate(null)
where won_count + lost_count <> closed_deals;

-- 2.4  The three segment types each cover the same deals. Their totals
--      must agree with each other and with snap_sourced_deal itself.
--
-- expected, snapshot 2026-09-14: three rows, all reading
--   272 closed  205 won  5886665.20 won_amount
-- and the triple-count warning made concrete - summing all 18 rows would
-- give 816 / 615 instead.
select segment_type,
       sum(closed_deals) as closed_deals,
       sum(won_count)    as won_count,
       sum(won_amount)   as won_amount
from mktg.f_close_rate(null)
where snapshot_date = '2026-09-14'
group by segment_type
order by segment_type;

-- 2.5  Straight from the table, bypassing the function entirely.
--
-- expected: 272  205  67  5886665.20  3524703.06
-- If 2.1's 'all' row disagrees with this, the function is wrong, not the
-- table.
select count(*)                                                        as closed_deals,
       count(*) filter (where is_closed_won)                           as won_count,
       count(*) filter (where not is_closed_won)                       as lost_count,
       sum(amount_home) filter (where is_closed_won)                   as won_amount,
       sum(amount_home) filter (where not is_closed_won)               as lost_amount
from mktg.snap_sourced_deal
where snapshot_date = '2026-09-14'
  and is_closed;

-- 2.6  History is preserved: every snapshot already written gets rates,
--      computed from the rows that snapshot holds.
--
-- expected: one row per snapshot_date from 2026-09-02 onward, 18 segments
-- each. The 09-02 to 09-13 rows were written under the OLD 2025-06-01
-- window anchor and cover a wider population, so a step change at
-- 2026-09-14 is the definition change documented in CLAUDE.md, not a
-- business event.
select snapshot_date, count(*) as segment_rows,
       max(closed_deals) filter (where segment_type = 'all')  as closed_deals,
       max(deal_win_rate) filter (where segment_type = 'all') as deal_win_rate,
       max(dollar_win_rate) filter (where segment_type = 'all') as dollar_win_rate
from mktg.f_close_rate(null)
group by snapshot_date
order by snapshot_date;

-- 2.7  The close_year parameter narrows to deals closing in one year.
--
-- expected: every closed deal in this snapshot closed in 2026 (earliest
-- 2026-01-08, latest 2026-09-02), so f_close_rate(2026) must return the
-- same 272 / 205 as f_close_rate(null), and f_close_rate(2025) must
-- return no rows at all.
select 2026 as close_year, closed_deals, won_count
from mktg.f_close_rate(2026)
where snapshot_date = '2026-09-14' and segment_type = 'all'
union all
select 2025, closed_deals, won_count
from mktg.f_close_rate(2025)
where snapshot_date = '2026-09-14' and segment_type = 'all';

-- 2.8  The view and the function agree, because they are one body.
--
-- expected: 0 rows
select * from mktg.v_close_rate
except
select * from mktg.f_close_rate(null);
