-- =====================================================================
-- UP: contact list behind MQLs by quarter
-- =====================================================================
-- Down version: 2026-10-04_mql_contact_list.down.sql
--
-- WHY
--   Alecia, 2026-10-04: show the contacts behind each quarter's MQL count
--   on the Pipeline Influence page, so a number can be checked when
--   someone questions it.
--
-- WHAT
--   1. snap_mql_entry gains contact_name, company_name, owner_name -
--      identity only, written by sync_to_mktg.py from the same HubSpot
--      read. Rows written before this are null until the next run.
--   2. mktg.f_mql_contacts(): one row per (snapshot_date, quarter,
--      contact) for exactly the contacts f_mql_by_quarter counts as
--      mqls - same exclusion, internal and Junk/Disqualified rules,
--      same Central-time quarter. Row count per quarter MUST equal
--      f_mql_by_quarter.mqls; VERIFY below checks it.
--      first_entered_at is the contact's earliest counted entry in that
--      quarter; entries_in_quarter says whether there were more.
--
-- EVERY snapshot_date, like every other f_* here. Filter server-side on
-- snapshot_date AND quarter_start.
--
-- ORDER OF OPERATIONS
--   1. Run PASTE 1 in the Supabase SQL editor.
--   2. Run the mql leg once to fill the new columns.
--   3. Run VERIFY.
-- =====================================================================


-- ============================== PASTE 1 ==============================

alter table mktg.snap_mql_entry
  add column if not exists contact_name text,
  add column if not exists company_name text,
  add column if not exists owner_name   text;

drop function if exists mktg.f_mql_contacts();

CREATE OR REPLACE FUNCTION mktg.f_mql_contacts()
 RETURNS TABLE(snapshot_date date, quarter_start date, quarter_label text,
               contact_id text, contact_name text, email text,
               company_name text, owner_name text, lead_source text,
               first_entered_at timestamptz, entered_status text,
               previous_status text, source_type text,
               current_lead_status text, entries_in_quarter bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with e as (
        select m.*,
               date_trunc('quarter', m.entered_at at time zone 'America/Chicago')::date as q
        from snap_mql_entry m
        where not m.is_internal
          and m.exclusion_reason is null
          and m.current_lead_status is distinct from 'JUNK'
          and m.current_lead_status is distinct from 'Disqualified'
    ),
    firsts as (
        select distinct on (snapshot_date, q, contact_id) *
        from e
        order by snapshot_date, q, contact_id, entered_at
    )
    select f.snapshot_date,
           f.q as quarter_start,
           'Q' || extract(quarter from f.q) || ' ' || extract(year from f.q) as quarter_label,
           f.contact_id,
           f.contact_name,
           f.email,
           f.company_name,
           f.owner_name,
           f.lead_source,
           f.entered_at as first_entered_at,
           f.entered_status,
           f.previous_status,
           f.source_type,
           f.current_lead_status,
           (select count(*) from e x
             where x.snapshot_date = f.snapshot_date
               and x.q = f.q
               and x.contact_id = f.contact_id) as entries_in_quarter
    from firsts f
    order by f.snapshot_date, f.q, f.entered_at;
$function$;

create or replace view mktg.v_mql_contacts as
select * from mktg.f_mql_contacts();

grant select on mktg.v_mql_contacts to authenticated;
grant execute on function mktg.f_mql_contacts() to authenticated;


-- ============================== VERIFY ===============================
-- List size per quarter must equal the headline count, every quarter.
-- Expect zero rows back.
--
-- select q.snapshot_date, q.quarter_label, q.mqls, count(c.contact_id) as listed
-- from mktg.f_mql_by_quarter() q
-- left join mktg.f_mql_contacts() c
--   on c.snapshot_date = q.snapshot_date and c.quarter_start = q.quarter_start
-- group by 1, 2, 3
-- having q.mqls <> count(c.contact_id);
