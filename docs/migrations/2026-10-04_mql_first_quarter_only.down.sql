-- =====================================================================
-- DOWN: back to "once per contact per quarter" MQL counting
-- =====================================================================
-- Reverses 2026-10-04_mql_first_quarter_only.sql: restores the bodies
-- from 2026-10-04_mql_by_quarter.sql and 2026-10-04_mql_contact_list.sql,
-- dropping repeat_contacts.

drop view if exists mktg.v_mql_by_quarter;
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

update mktg.config_settings
   set value = 'Contacts whose Lead Status entered Awaiting Sales Qualification in the '
               'quarter and is not now Junk or Disqualified. Each contact counted once '
               'per quarter.',
       updated_at = now()
 where key = 'label_mql_by_quarter';
