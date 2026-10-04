-- =====================================================================
-- UP: Marketing Qualified Leads generated per quarter
-- =====================================================================
-- Down version: 2026-10-04_mql_by_quarter.down.sql
--
-- DEFINITION (Alecia, 2026-10-04)
--   An MQL generated in quarter Q is a contact whose HubSpot Lead Status
--   ENTERED "Awaiting Sales Qualification" (or "Awaiting Sales
--   Qualification - Returning", stored as 'Returning Customer') during Q,
--   and whose Lead Status TODAY is not Junk or Disqualified. Once per
--   contact per quarter; a contact entering again in a later quarter
--   counts again there. Quarters are US Central calendar quarters.
--
--   "Entered" comes from the hs_lead_status property history, not from
--   the custom previous_lead_status field (labels, not values, and wrong
--   on almost every contact) - see generate_mql_report.py's docstring.
--
-- EXCLUSIONS (ratified 2026-10-04), frozen per row at ETL time from
-- generate_mql_report.MQL_EXCLUSIONS - the single source:
--   workflow_misfire_2026_05_25       ~5,800 contacts set by a misfired
--                                     workflow, partly restored the same
--                                     day. Would add ~4,640 to Q2 2026.
--   nurture_recycle_batch_2026_09_21  122 Nurture contacts moved in one
--                                     automated batch, mostly straight
--                                     back to Nurture. Recycled, not new.
--   Excluded entries are still stored, so the effect is auditable and an
--   exclusion can be reversed without a HubSpot re-pull.
--
-- GRAIN
--   mktg.snap_mql_entry: one row per (snapshot_date, contact_id,
--   entered_at) - one per ENTRY, so a contact entering twice has two rows.
--   Never count rows. f_mql_by_quarter counts DISTINCT contact_id per
--   quarter, which is what makes "once per contact per quarter" hold.
--   current_lead_status repeats on every row of a contact by design.
--
-- KNOWN BIAS, by definition not by bug: an older quarter has had longer
--   for its MQLs to be disqualified, so the "today is not Junk/DQ" rule
--   trims Q1 harder than Q3. Verified 2026-10-04: Q1 lost 53 of 126 to
--   Junk/DQ, Q3 lost 52 of 265.
--
-- EVERY snapshot_date, like every other f_* here. Filter server-side.
--
-- ORDER OF OPERATIONS
--   1. Run PASTE 1 in the Supabase SQL editor.
--   2. Run `python sync_to_mktg.py --only mql` once. With no prior
--      snapshot it reads every contact (~1,000 HubSpot calls, 15-20 min).
--      Daily runs after that are incremental.
--   3. Run the VERIFY queries at the bottom.
--
-- No explicit BEGIN: a multi-statement paste is one implicit transaction.
-- =====================================================================


-- ============================== PASTE 1 ==============================

create table if not exists mktg.snap_mql_entry (
    snapshot_date        date        not null references mktg.run_log (snapshot_date),
    contact_id           text        not null,
    entered_at           timestamptz not null,
    entered_status       text        not null,
    previous_status      text,
    source_type          text,
    exclusion_reason     text,
    current_lead_status  text,
    email                text,
    lead_source          text,
    is_internal          boolean     not null default false,
    is_seeded            boolean     not null default false,
    primary key (snapshot_date, contact_id, entered_at)
);

comment on table mktg.snap_mql_entry is
  'One row per entry into Lead Status Awaiting Sales Qualification (or '
  'Returning Customer), per snapshot. Entry grain - count DISTINCT '
  'contact_id, never rows. Written by sync_to_mktg.py from '
  'generate_mql_report.py. Rolled up by f_mql_by_quarter().';
comment on column mktg.snap_mql_entry.exclusion_reason is
  'Null = counts. Otherwise the generate_mql_report.MQL_EXCLUSIONS rule '
  'that excluded this entry, frozen at ETL time.';

alter table mktg.snap_mql_entry enable row level security;
drop policy if exists snap_mql_entry_select_authenticated on mktg.snap_mql_entry;
create policy snap_mql_entry_select_authenticated on mktg.snap_mql_entry
  for select to authenticated using (true);
grant select on mktg.snap_mql_entry to authenticated;
grant select, insert, update, delete on mktg.snap_mql_entry to service_role;

drop function if exists mktg.f_mql_by_quarter();

CREATE OR REPLACE FUNCTION mktg.f_mql_by_quarter()
 RETURNS TABLE(snapshot_date date, quarter_start date, quarter_label text,
               entered_contacts bigint, now_junk_or_disqualified bigint,
               mqls bigint, excluded_contacts bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with e as (
        select snapshot_date,
               contact_id,
               date_trunc('quarter', entered_at at time zone 'America/Chicago')::date as quarter_start,
               exclusion_reason,
               current_lead_status in ('JUNK', 'Disqualified') as is_junk_or_dq
        from snap_mql_entry
        where not is_internal
    ),
    span as (
        select snapshot_date,
               min(quarter_start) as q0,
               date_trunc('quarter', snapshot_date::timestamp)::date as q1
        from e
        group by snapshot_date
    ),
    quarters as (
        select s.snapshot_date, g::date as quarter_start
        from span s
        cross join lateral generate_series(s.q0::timestamp, s.q1::timestamp, interval '3 months') g
    )
    select q.snapshot_date,
           q.quarter_start,
           'Q' || extract(quarter from q.quarter_start) || ' ' || extract(year from q.quarter_start) as quarter_label,
           count(distinct e.contact_id) filter (where e.exclusion_reason is null)                         as entered_contacts,
           count(distinct e.contact_id) filter (where e.exclusion_reason is null and e.is_junk_or_dq)     as now_junk_or_disqualified,
           count(distinct e.contact_id) filter (where e.exclusion_reason is null and not e.is_junk_or_dq) as mqls,
           count(distinct e.contact_id) filter (where e.exclusion_reason is not null)                     as excluded_contacts
    from quarters q
    left join e
           on e.snapshot_date = q.snapshot_date
          and e.quarter_start = q.quarter_start
    group by q.snapshot_date, q.quarter_start
    order by q.snapshot_date, q.quarter_start;
$function$;

create or replace view mktg.v_mql_by_quarter as
select * from mktg.f_mql_by_quarter();

grant select on mktg.v_mql_by_quarter to authenticated;
grant execute on function mktg.f_mql_by_quarter() to authenticated;

insert into mktg.config_settings (key, value, value_type, description)
values
  ('label_mql_by_quarter',
   'Contacts whose Lead Status entered Awaiting Sales Qualification in the '
   'quarter and is not now Junk or Disqualified. Each contact counted once '
   'per quarter.', 'text',
   'Caption for f_mql_by_quarter / v_mql_by_quarter. Definition per Alecia '
   '2026-10-04. Excludes the 2026-05-25 workflow misfire and the '
   '2026-09-21 Nurture recycle batch.')
on conflict (key) do update
  set value = excluded.value,
      value_type = excluded.value_type,
      description = excluded.description,
      updated_at = now();


-- ============================== VERIFY ===============================
-- After the first `sync_to_mktg.py --only mql`. Expected on 2026-10-04
-- (moves daily; quarter edges use Central time, so +/- a few):
--   Q1 2026  entered ~126  mqls ~73
--   Q2 2026  entered ~228  mqls ~192
--   Q3 2026  entered ~265  mqls ~213
--
-- select * from mktg.f_mql_by_quarter()
-- where snapshot_date = (select max(snapshot_date) from mktg.snap_mql_entry);
--
-- Rows vs distinct contacts vs excluded, proving grain:
-- select count(*) as entry_rows,
--        count(distinct contact_id) as contacts,
--        count(*) filter (where exclusion_reason is not null) as excluded_rows,
--        exclusion_reason
-- from mktg.snap_mql_entry
-- where snapshot_date = (select max(snapshot_date) from mktg.snap_mql_entry)
-- group by rollup (exclusion_reason);
