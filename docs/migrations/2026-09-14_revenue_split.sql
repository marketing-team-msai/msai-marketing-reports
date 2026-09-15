-- =====================================================================
-- UP: company-wide revenue split - marketing vs sales, closed-won vs open
-- =====================================================================
-- Down version: 2026-09-14_revenue_split.down.sql
--
-- WHY THIS EXISTS
--   The "Marketing contribution to the 2026 company revenue target" card
--   (Overview and Influence pages) could only ever show marketing's
--   figures, because its only data source, snap_influence, has ONE ROW PER
--   INFLUENCED DEAL - a deal marketing never touched simply has no row
--   there. Its own caption said so: "company-wide bookings from deals
--   marketing never touched are not in this data." Alecia asked
--   2026-09-14 to show marketing closed won + sales closed won, and
--   separately marketing still open + sales still open, so the bar
--   reflects true company-wide progress against the $15M target, not just
--   marketing's share of it. Confirmed scope: every HubSpot pipeline,
--   company-wide (not just the Net New Pipeline snap_sourced_deal already
--   covers).
--
-- NEW OBJECTS
--   mktg.snap_all_deals   new snap_* table (entity-grain, one row per deal,
--                         portal-wide, EVERY pipeline - not just Net New).
--                         Written by the EXISTING generate_report.py pull
--                         (it already fetches every deal in every pipeline
--                         to compute influenced_deal_ids; this just also
--                         persists the full population instead of
--                         discarding it), via a new row builder in
--                         sync_to_mktg.py's existing run_influence() job -
--                         no new HubSpot scope, no new generator script,
--                         no new daily job. is_influenced reuses the exact
--                         same "any associated contact is in a Campaign
--                         Influence list" rule already backing
--                         snap_influence / f_influence_headline.
--   mktg.f_event_roi -- not part of this migration, see
--                         2026-09-14_events_page.sql.
--   mktg.f_revenue_split / v_revenue_split
--                         Always exactly 4 rows per (snapshot_date,
--                         close_year, include_amazon): marketing/
--                         closed_won, marketing/open, sales/closed_won,
--                         sales/open. "open" means not is_closed (still
--                         active) - closed-LOST deals are excluded from
--                         both closed_won and open, same as they should be
--                         for a revenue-target progress bar. Returns every
--                         snapshot_date: filter server-side, same
--                         load-bearing rule as every other f_* function
--                         here.
--
-- WHAT THIS DOES NOT DO
--   Does not touch snap_influence, snap_sourced_deal, or any existing
--   view/function. Does not change any existing figure on Overview/
--   Influence other than the revenue-contribution card itself (a frontend
--   change, not part of this migration). Does not filter on is_internal /
--   is_storefront the way f_influence_headline does - those are deal x
--   CONTACT-level flags (which contact is on which side of a deal), which
--   do not translate cleanly onto a deal-only table with no contact rows.
--   is_storefront is hard-coded false everywhere already; is_internal
--   affects a small enough population (18 contacts portal-wide, per
--   CLAUDE.md) that this is a documented simplification, not a silent gap.
--
-- Paste PASTE 1 into the Supabase SQL editor and Run. Then paste PASTE 2
-- and Run once real data exists (after sync_to_mktg.py has run at least
-- once post-migration).
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres.
-- =====================================================================


-- ============================== PASTE 1 ==============================

create table if not exists mktg.snap_all_deals (
    snapshot_date  date    not null references mktg.run_log (snapshot_date),
    deal_id        text    not null,
    deal_name      text,
    company_name   text,
    pipeline       text,
    stage          text,
    close_date     date,
    create_date    date,
    amount_home    numeric,
    is_won         boolean not null default false,
    is_closed      boolean not null default false,
    is_influenced  boolean not null default false,
    is_amazon      boolean not null default false,
    is_galco       boolean not null default false,
    is_seeded      boolean not null default false,
    primary key (snapshot_date, deal_id)
);

grant select on mktg.snap_all_deals to authenticated;


-- ---------------------------------------------------------------------
-- f_revenue_split - always 4 rows: (marketing, sales) x (closed_won, open).
-- ---------------------------------------------------------------------
drop function if exists mktg.f_revenue_split(integer, boolean);

create or replace function mktg.f_revenue_split(
    close_year     integer default 2026,
    include_amazon boolean default true)
returns table (
    snapshot_date date,
    segment       text,
    status        text,
    deals         bigint,
    amount        numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
    with scope as (
        select snapshot_date, deal_id, amount_home,
               case when is_influenced then 'marketing' else 'sales' end as segment,
               case when is_won then 'closed_won'
                    when not is_closed then 'open'
                    else null end as status
        from snap_all_deals
        where (include_amazon or not is_amazon)
          and extract(year from close_date) = close_year
    ),
    days as (
        select distinct snapshot_date from snap_all_deals
    ),
    segments (segment, sort_order) as (
        values ('marketing', 1), ('sales', 2)
    ),
    statuses (status, sort_order) as (
        values ('closed_won', 1), ('open', 2)
    )
    select dy.snapshot_date, sg.segment, st.status,
           count(s.deal_id), coalesce(sum(s.amount_home), 0)
    from days dy
    cross join segments sg
    cross join statuses st
    left join scope s
           on s.snapshot_date = dy.snapshot_date
          and s.segment = sg.segment
          and s.status  = st.status
    group by dy.snapshot_date, sg.segment, sg.sort_order, st.status, st.sort_order
    order by dy.snapshot_date, sg.sort_order, st.sort_order;
$function$;

create or replace view mktg.v_revenue_split as
    select * from mktg.f_revenue_split(2026, true);

grant execute on function mktg.f_revenue_split(integer, boolean) to authenticated;
grant select on mktg.v_revenue_split to authenticated;

comment on table mktg.snap_all_deals is
  'Portal-wide, every pipeline, one row per deal regardless of marketing '
  'influence - unlike snap_influence, which only has rows for deals '
  'marketing touched. is_influenced reuses the exact rule already backing '
  'snap_influence/f_influence_headline. Written by the existing '
  'generate_report.py pull via sync_to_mktg.py''s run_influence() - no new '
  'HubSpot scope or daily job.';

comment on function mktg.f_revenue_split(integer, boolean) is
  'Company-wide 2026 revenue split into marketing vs sales, closed_won vs '
  'open. Always 4 rows. "open" excludes closed-lost deals (not is_closed), '
  'unlike the old marketing-only card which lumped lost deals into '
  '"still open". Returns every snapshot_date: filter server-side.';


-- ============================== PASTE 2 ==============================
-- Verification. Run after sync_to_mktg.py has synced at least once
-- post-migration (snap_all_deals needs real rows first).

-- 2.1  Shape: exactly 4 rows for the latest snapshot, in a stable order.
--
-- expected: marketing/closed_won, marketing/open, sales/closed_won,
-- sales/open, in that order
select segment, status, deals, amount
from mktg.f_revenue_split(2026, true)
where snapshot_date = (select max(snapshot_date) from mktg.run_log where status = 'ok');

-- 2.2  Reconciliation: marketing + sales must equal the true company
--      total for each status - the whole point of this feature.
--
-- expected: 0 rows
with latest as (
    select max(snapshot_date) as d from mktg.run_log where status = 'ok'
),
split as (
    select * from mktg.f_revenue_split(2026, true), latest
    where snapshot_date = latest.d
),
total as (
    select
        case when is_won then 'closed_won' when not is_closed then 'open' end as status,
        sum(amount_home) as amount
    from mktg.snap_all_deals, latest
    where snapshot_date = latest.d
    group by 1
)
select t.status, t.amount as true_total,
       (select sum(amount) from split s where s.status = t.status) as split_total
from total t
where t.status is not null
  and round(t.amount, 2) <> round(coalesce((select sum(amount) from split s
                                             where s.status = t.status), 0), 2);

-- 2.3  Every deal in snap_all_deals with a Campaign Influence touch also
--      has at least one row in snap_influence for the same snapshot - the
--      two tables should agree on WHICH deals are influenced, even though
--      their totals are not comparable (portal-wide all-deals here vs
--      portal-wide influenced-only there - same population, so they
--      should actually match exactly, unlike snap_influence vs the
--      Net-New-only snap_sourced_deal).
--
-- expected: 0 rows
select d.deal_id
from mktg.snap_all_deals d
where d.is_influenced
  and d.snapshot_date = (select max(snapshot_date) from mktg.run_log where status = 'ok')
  and not exists (
      select 1 from mktg.snap_influence i
      where i.deal_id = d.deal_id and i.snapshot_date = d.snapshot_date
  );
