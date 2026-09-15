-- =====================================================================
-- UP: Events page - event roster, budget/actual cost, funnel snapshot,
--     ROI function/view, and restricted write access
-- =====================================================================
-- Down version: 2026-09-14_events_page.down.sql
--
-- WHY THIS EXISTS
--   Alecia has a standalone Excel model (MSAI_Tradeshow_ROI_Model) that
--   computes, per tradeshow: capture rate, qualification rate, lead-MQL
--   rate, MQL-SQL rate, SQL-opportunity rate, cost per lead/MQL/SQL/
--   opportunity, and a GOOD/REVIEW cost-efficiency flag vs the event
--   cohort's median. She wants the same methodology live on the "Events"
--   page of msai-marketing-dash, sourced from HubSpot Campaign Influence
--   list membership directly (not the spreadsheet), with budget-vs-actual
--   cost entered by hand as it comes in.
--
--   Nothing here existed before this migration: no event entity, no cost
--   concept, no manual-write path anywhere in mktg.
--
-- NEW OBJECTS
--   mktg.event              hand-maintained roster (like config_*, NOT
--                            snapshot-grained). One row per real-world
--                            event: name, date, type, location, and
--                            actual_attendees (manual - HubSpot carries no
--                            attendance data at all).
--   mktg.event_hubspot_list  which HubSpot Campaign Influence list(s) map
--                            to each event - discovered to be one-to-MANY
--                            2026-09-14 (The Reliability Conference has a
--                            separate "Booth" list and "Collateral" list,
--                            both the same event, different lead-capture
--                            channels at the show). A HubSpot list still
--                            belongs to exactly one event (unique
--                            constraint on hubspot_list_id) - it is the
--                            event side that can be one-to-many, not the
--                            list side.
--   mktg.event_cost          hand-maintained budget vs actual, one row per
--                            event. Separate table from mktg.event so its
--                            write policy does not have to also cover the
--                            event's own metadata.
--   mktg.event_editor        allowlist of emails permitted to write to
--                            event / event_cost. Confirmed with Alecia
--                            2026-09-14: write access is restricted to
--                            specific people, not every signed-in
--                            employee (a first for this schema - every
--                            other table only reads via `authenticated`
--                            and is written by the service-role ETL).
--                            No grants to `authenticated` at all: managed
--                            by hand in the SQL editor, same as any other
--                            admin-only table.
--   mktg.snap_event_funnel   new daily snapshot (entity-grain, exactly the
--                            snap_* convention: COUNTS ONLY, no aggregation
--                            here). One row per (snapshot_date, event_id):
--                            names_captured, leads, mqls, sqls,
--                            opportunities, straight off each event's
--                            HubSpot list contacts bucketed by
--                            lifecyclestage. Written daily by the new
--                            generate_events_report.py, wired into
--                            sync_to_mktg.py the same way as the other 3
--                            reports.
--   mktg.f_event_roi / v_event_roi
--                            joins the three above and computes the 5
--                            funnel rates, 4 cost-per-stage figures (off
--                            ACTUAL cost), a live cohort-median GOOD/REVIEW
--                            cost-efficiency flag (recomputed per
--                            snapshot_date across whatever events have
--                            data - never a stale hard-coded baseline like
--                            the workbook's), and a separate ON BUDGET /
--                            OVER BUDGET flag from actual vs budget. These
--                            answer different questions - efficient vs
--                            peers, on plan vs what was told to finance -
--                            and are deliberately not combined into one
--                            flag.
--
-- STAGE BUCKETING, SAME TWO FOLDING RULES AS THE WORKBOOK (ratified there
-- 2026-07-16, applied here because HubSpot's list membership carries no
-- separate signal for events):
--   leads         = lifecyclestage 'lead'
--   mqls          = lifecyclestage 'marketingqualifiedlead'
--   sqls          = lifecyclestage '157687207' (custom "Sales Accepted
--                   Lead" stage, same portal-specific id already used in
--                   generate_netnew_report.LIFECYCLE_ORDER) OR
--                   'salesqualifiedlead'
--   opportunities = lifecyclestage 'opportunity' OR 'customer' OR
--                   '1157693063' (Repeat Customer - not in the workbook's
--                   documented rule, folded in here for completeness since
--                   it is later in the same lifecycle than Customer;
--                   flag to Alecia if that should NOT fold in)
--   Opportunity is a lifecycle stage on the CONTACT record, not a Deal -
--   same rule as the workbook. This migration does NOT join
--   snap_influence/snap_sourced_deal for events; that is a possible
--   fast-follow (campaign_id there already equals hubspot_list_id here)
--   but is out of scope for this first cut.
--
-- WHAT THIS DOES NOT DO
--   Does not touch any existing table, view, or function. Does not change
--   how influenced pipeline, sourced pipeline, or SLA are computed.
--   Does not build an "influenced pipeline $" figure for events - counts
--   only, matching the ratified contacts-by-stage rule elsewhere in this
--   schema (see CLAUDE.md "Ratified rules").
--
-- SEEDING
--   This migration creates empty tables. Nothing renders on the Events
--   page until:
--     1. rows are added to mktg.event_editor (by hand, in the SQL editor)
--     2. a row is added to mktg.event, and one row per HubSpot list to
--        mktg.event_hubspot_list (by hand, or later via the app's "Add
--        Event" form once built)
--     3. generate_events_report.py has run at least once via
--        `python sync_to_mktg.py --only events`
--
-- Paste PASTE 1 into the Supabase SQL editor and Run. Then paste PASTE 2
-- and Run to confirm the objects exist and RLS behaves as expected -
-- there is no business data to check numbers against yet.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres.
-- =====================================================================


-- ============================== PASTE 1 ==============================

create table if not exists mktg.event (
    event_id          text primary key,
    event_name        text not null,
    event_date        date,
    event_type        text,
    location          text,
    actual_attendees  integer,
    created_at        timestamptz not null default now(),
    created_by        text,
    is_seeded         boolean not null default false
);

-- One event can map to more than one HubSpot Campaign Influence list (e.g.
-- a separate "Booth" list and "Collateral" list for the same show, each a
-- different lead-capture channel). A list, though, belongs to exactly one
-- event - the unique constraint on hubspot_list_id enforces that side.
create table if not exists mktg.event_hubspot_list (
    event_id         text not null references mktg.event (event_id) on delete cascade,
    hubspot_list_id  text not null unique,
    label            text,
    primary key (event_id, hubspot_list_id)
);

create table if not exists mktg.event_cost (
    event_id     text primary key references mktg.event (event_id) on delete cascade,
    budget_cost  numeric,
    actual_cost  numeric,
    cost_notes   text,
    updated_at   timestamptz not null default now(),
    updated_by   text
);

create table if not exists mktg.event_editor (
    email  text primary key
);

create table if not exists mktg.snap_event_funnel (
    snapshot_date   date    not null references mktg.run_log (snapshot_date),
    event_id        text    not null references mktg.event (event_id),
    names_captured  integer not null default 0,
    leads           integer not null default 0,
    mqls            integer not null default 0,
    sqls            integer not null default 0,
    opportunities   integer not null default 0,
    is_seeded       boolean not null default false,
    primary key (snapshot_date, event_id)
);


-- ---------------------------------------------------------------------
-- is_event_editor() - security definer so it can read event_editor (which
-- `authenticated` has no grant on at all) while running as its owner.
-- RLS policies below call this instead of each repeating the same
-- subquery, so there is one place this rule lives.
-- ---------------------------------------------------------------------
drop function if exists mktg.is_event_editor();

create or replace function mktg.is_event_editor()
returns boolean
language sql
stable
security definer
set search_path to 'mktg'
as $function$
    select exists (
        select 1 from mktg.event_editor
        where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$function$;


-- ---------------------------------------------------------------------
-- RLS. event / event_cost: SELECT open to any authenticated user, matching
-- the read model everywhere else in this schema. INSERT/UPDATE restricted
-- to the event_editor allowlist - the one place in mktg this differs from
-- "every signed-in employee has the same access."
--
-- event_editor itself: RLS enabled, no policies and no grants to
-- authenticated at all, so it is invisible and unwritable through the API
-- for every role except service_role/the table owner. Manage it by hand in
-- the SQL editor.
-- ---------------------------------------------------------------------
alter table mktg.event enable row level security;
alter table mktg.event_hubspot_list enable row level security;
alter table mktg.event_cost enable row level security;
alter table mktg.event_editor enable row level security;
alter table mktg.snap_event_funnel enable row level security;

drop policy if exists event_select_authenticated on mktg.event;
create policy event_select_authenticated on mktg.event
    for select to authenticated using (true);

drop policy if exists event_insert_editor on mktg.event;
create policy event_insert_editor on mktg.event
    for insert to authenticated with check (mktg.is_event_editor());

drop policy if exists event_update_editor on mktg.event;
create policy event_update_editor on mktg.event
    for update to authenticated using (mktg.is_event_editor())
    with check (mktg.is_event_editor());

drop policy if exists event_hubspot_list_select_authenticated on mktg.event_hubspot_list;
create policy event_hubspot_list_select_authenticated on mktg.event_hubspot_list
    for select to authenticated using (true);

drop policy if exists event_hubspot_list_insert_editor on mktg.event_hubspot_list;
create policy event_hubspot_list_insert_editor on mktg.event_hubspot_list
    for insert to authenticated with check (mktg.is_event_editor());

drop policy if exists event_hubspot_list_delete_editor on mktg.event_hubspot_list;
create policy event_hubspot_list_delete_editor on mktg.event_hubspot_list
    for delete to authenticated using (mktg.is_event_editor());

drop policy if exists event_cost_select_authenticated on mktg.event_cost;
create policy event_cost_select_authenticated on mktg.event_cost
    for select to authenticated using (true);

drop policy if exists event_cost_insert_editor on mktg.event_cost;
create policy event_cost_insert_editor on mktg.event_cost
    for insert to authenticated with check (mktg.is_event_editor());

drop policy if exists event_cost_update_editor on mktg.event_cost;
create policy event_cost_update_editor on mktg.event_cost
    for update to authenticated using (mktg.is_event_editor())
    with check (mktg.is_event_editor());

-- snap_event_funnel: read-only to authenticated, written only by the
-- service-role ETL (which bypasses RLS), same as every other snap_* table.
drop policy if exists snap_event_funnel_select_authenticated on mktg.snap_event_funnel;
create policy snap_event_funnel_select_authenticated on mktg.snap_event_funnel
    for select to authenticated using (true);

grant select, insert, update on mktg.event to authenticated;
grant select, insert, delete on mktg.event_hubspot_list to authenticated;
grant select, insert, update on mktg.event_cost to authenticated;
grant select on mktg.snap_event_funnel to authenticated;
grant execute on function mktg.is_event_editor() to authenticated;
-- Deliberately NO grant on mktg.event_editor to authenticated.


-- ---------------------------------------------------------------------
-- f_event_roi - the 5 funnel rates, 4 cost-per-stage figures, a live
-- cohort-median GOOD/REVIEW cost-efficiency flag, and a separate ON
-- BUDGET/OVER BUDGET flag. Returns every snapshot_date, same load-bearing
-- rule as every other f_* function here: the caller filters server-side.
-- ---------------------------------------------------------------------
drop function if exists mktg.f_event_roi();

create or replace function mktg.f_event_roi()
returns table (
    snapshot_date         date,
    event_id              text,
    event_name            text,
    event_date            date,
    event_type            text,
    location              text,
    actual_attendees      integer,
    names_captured        integer,
    leads                 integer,
    mqls                  integer,
    sqls                  integer,
    opportunities         integer,
    budget_cost           numeric,
    actual_cost           numeric,
    capture_rate          numeric,
    qual_rate             numeric,
    lead_mql_rate         numeric,
    mql_sql_rate          numeric,
    sql_opp_rate          numeric,
    cost_per_lead         numeric,
    cost_per_mql          numeric,
    cost_per_sql          numeric,
    cost_per_opportunity  numeric,
    cost_per_sql_median   numeric,
    cost_efficiency       text,
    budget_variance       numeric,
    budget_status         text
)
language sql
stable
set search_path to 'mktg'
as $function$
    with base as (
        select f.snapshot_date, e.event_id, e.event_name, e.event_date,
               e.event_type, e.location, e.actual_attendees,
               f.names_captured, f.leads, f.mqls, f.sqls, f.opportunities,
               c.budget_cost, c.actual_cost
        from snap_event_funnel f
        join event e on e.event_id = f.event_id
        left join event_cost c on c.event_id = e.event_id
    ),
    calc as (
        select b.*,
            case when b.actual_attendees > 0
                 then b.names_captured::numeric / b.actual_attendees end
                as capture_rate,
            case when b.names_captured > 0
                 then (b.leads + b.mqls + b.sqls + b.opportunities)::numeric
                      / b.names_captured end
                as qual_rate,
            case when (b.leads + b.mqls + b.sqls + b.opportunities) > 0
                 then (b.mqls + b.sqls + b.opportunities)::numeric
                      / (b.leads + b.mqls + b.sqls + b.opportunities) end
                as lead_mql_rate,
            case when (b.mqls + b.sqls + b.opportunities) > 0
                 then (b.sqls + b.opportunities)::numeric
                      / (b.mqls + b.sqls + b.opportunities) end
                as mql_sql_rate,
            case when (b.sqls + b.opportunities) > 0
                 then b.opportunities::numeric / (b.sqls + b.opportunities) end
                as sql_opp_rate,
            case when b.actual_cost is not null
                      and (b.leads + b.mqls + b.sqls + b.opportunities) > 0
                 then b.actual_cost
                      / (b.leads + b.mqls + b.sqls + b.opportunities) end
                as cost_per_lead,
            case when b.actual_cost is not null
                      and (b.mqls + b.sqls + b.opportunities) > 0
                 then b.actual_cost / (b.mqls + b.sqls + b.opportunities) end
                as cost_per_mql,
            case when b.actual_cost is not null
                      and (b.sqls + b.opportunities) > 0
                 then b.actual_cost / (b.sqls + b.opportunities) end
                as cost_per_sql,
            case when b.actual_cost is not null and b.opportunities > 0
                 then b.actual_cost / b.opportunities end
                as cost_per_opportunity
        from base b
    ),
    -- percentile_cont is an ORDERED-SET aggregate: Postgres does not allow
    -- OVER on those (only on true window functions), so the median is a
    -- plain GROUP BY aggregate here, joined back to calc on snapshot_date,
    -- rather than a window function over calc directly. It naturally
    -- ignores nulls (events with no actual_cost or no sqls+opportunities),
    -- same as a window function would have.
    medians as (
        select snapshot_date,
               percentile_cont(0.5) within group (order by cost_per_sql)
                   as cost_per_sql_median
        from calc
        group by snapshot_date
    )
    select c.snapshot_date, c.event_id, c.event_name, c.event_date,
           c.event_type, c.location, c.actual_attendees, c.names_captured,
           c.leads, c.mqls, c.sqls, c.opportunities, c.budget_cost,
           c.actual_cost, c.capture_rate, c.qual_rate, c.lead_mql_rate,
           c.mql_sql_rate, c.sql_opp_rate, c.cost_per_lead, c.cost_per_mql,
           c.cost_per_sql, c.cost_per_opportunity, m.cost_per_sql_median,
           case when c.cost_per_sql is null then null
                when c.cost_per_sql <= m.cost_per_sql_median then 'GOOD'
                else 'REVIEW' end as cost_efficiency,
           case when c.budget_cost is not null and c.actual_cost is not null
                then c.actual_cost - c.budget_cost end as budget_variance,
           case when c.budget_cost is null or c.actual_cost is null then null
                when c.actual_cost <= c.budget_cost then 'ON BUDGET'
                else 'OVER BUDGET' end as budget_status
    from calc c
    join medians m on m.snapshot_date = c.snapshot_date;
$function$;

create or replace view mktg.v_event_roi as
    select * from mktg.f_event_roi();

grant execute on function mktg.f_event_roi() to authenticated;
grant select on mktg.v_event_roi to authenticated;


comment on table mktg.event is
  'Hand-maintained event roster (like config_*, not snapshot-grained). One '
  'row per real-world event. The HubSpot Campaign Influence list(s) it '
  'pulls from live in event_hubspot_list, not here - it is one-to-many. '
  'actual_attendees is manual - HubSpot has no attendance data. Writable '
  'only by mktg.event_editor members (see is_event_editor()).';

comment on table mktg.event_hubspot_list is
  'Which HubSpot Campaign Influence list(s) map to each event. '
  'One-to-many on the event side (a show can have a separate Booth list '
  'and Collateral list, discovered 2026-09-14 with The Reliability '
  'Conference); hubspot_list_id is UNIQUE, so a list belongs to exactly '
  'one event. generate_events_report.py unions the contacts across every '
  'list for an event before bucketing by lifecycle stage, so a contact on '
  'two of an event''s lists is not double-counted. Writable only by '
  'mktg.event_editor members.';

comment on table mktg.event_cost is
  'Hand-maintained budget vs actual cost, one row per event. actual_cost '
  'drives every cost-per-stage figure in f_event_roi. Writable only by '
  'mktg.event_editor members.';

comment on table mktg.event_editor is
  'Allowlist of emails permitted to write to event / event_cost. No API '
  'grants at all - manage by hand in the SQL editor, same as any other '
  'admin-only table.';

comment on table mktg.snap_event_funnel is
  'Entity-grain daily snapshot, one row per (snapshot_date, event_id): '
  'names_captured/leads/mqls/sqls/opportunities off each event''s HubSpot '
  'Campaign Influence list, bucketed by contact lifecyclestage. Counts '
  'only, same rule as snap_sourced_contact - see CLAUDE.md "Ratified '
  'rules". Written daily by generate_events_report.py via sync_to_mktg.py, '
  'never by the app.';

comment on function mktg.f_event_roi() is
  'Per-event funnel rates, cost-per-stage (off actual_cost), a live '
  'cohort-median GOOD/REVIEW cost-efficiency flag recomputed per '
  'snapshot_date, and a separate ON BUDGET/OVER BUDGET flag from actual vs '
  'budget. The two flags answer different questions and are deliberately '
  'not combined. Returns every snapshot_date: filter server-side, same '
  'rule as every other f_* function here.';


-- ============================== PASTE 2 ==============================
-- Verification. No business data exists yet, so this checks the objects
-- and the access rules, not numbers.

-- 2.1  Tables and RLS are all present.
--
-- expected: 5 rows, rowsecurity = true on every one
select relname, relrowsecurity
from pg_class
where relnamespace = 'mktg'::regnamespace
  and relname in ('event', 'event_hubspot_list', 'event_cost', 'event_editor',
                  'snap_event_funnel')
order by relname;

-- 2.2  authenticated has no access at all to event_editor.
--
-- expected: 0 rows
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'mktg' and table_name = 'event_editor'
  and grantee = 'authenticated';

-- 2.3  authenticated can read and write event / event_hubspot_list /
--      event_cost, read-only on snap_event_funnel.
--
-- expected: event and event_cost each show SELECT, INSERT, UPDATE;
-- event_hubspot_list shows SELECT, INSERT, DELETE; snap_event_funnel shows
-- SELECT only
select table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'mktg' and grantee = 'authenticated'
  and table_name in ('event', 'event_hubspot_list', 'event_cost',
                      'snap_event_funnel')
order by table_name, privilege_type;

-- 2.4  f_event_roi returns the right shape on an empty schema.
--
-- expected: 0 rows, no error
select * from mktg.f_event_roi();

-- 2.5  is_event_editor() is callable and honest with no rows in the
--      allowlist.
--
-- expected: false
select mktg.is_event_editor();
