-- =====================================================================
-- UP: an MQL counts only in the first quarter the contact ever entered
-- =====================================================================
-- Down version: 2026-10-04_mql_first_quarter_only.down.sql
--
-- DEFINITION CHANGE (Alecia, 2026-10-04, same day as the original build)
--   Replaces "once per contact per quarter, re-entry in a later quarter
--   counts again". A contact now counts as an MQL only in the FIRST
--   quarter it ever entered Awaiting Sales Qualification / Returning
--   Customer. ANY earlier-quarter entry disqualifies a later one -
--   including entries tagged with an exclusion_reason (the 2026-05-25
--   misfire, the 2026-09-21 Nurture batch). Alecia chose that stricter
--   reading explicitly: having been put in the status at all, even by
--   the misfire, means the contact is not new.
--   Entries within the same quarter are unaffected: a contact misfired
--   on 2026-05-25 that genuinely entered later in Q2 still counts in Q2.
--   "Earlier" reaches back to the start of hs_lead_status history for
--   this status, August 2025.
--
-- EFFECT, verified live 2026-10-04 before applying:
--   Q1 2026  73 -> 70     Q2 2026  192 -> 186
--   Q3 2026 213 -> 153    (38 real repeats + 22 misfire-only repeats)
--   Q4 2026  30 -> 30
--
-- f_mql_by_quarter gains repeat_contacts (entered in the quarter, not
-- excluded, but had an earlier-quarter entry). Adding a column changes
-- the return type, so the view and function are dropped and recreated -
-- create or replace cannot do it - and grants are re-issued.
-- f_mql_contacts keeps its columns; its body changes the same way so
-- list length still equals mqls.
--
-- Run PASTE 1 in the Supabase SQL editor, then VERIFY.
-- =====================================================================


-- ============================== PASTE 1 ==============================

drop view if exists mktg.v_mql_by_quarter;
drop function if exists mktg.f_mql_by_quarter();

CREATE OR REPLACE FUNCTION mktg.f_mql_by_quarter()
 RETURNS TABLE(snapshot_date date, quarter_start date, quarter_label text,
               entered_contacts bigint, now_junk_or_disqualified bigint,
               mqls bigint, excluded_contacts bigint, repeat_contacts bigint)
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
    -- First quarter the contact ever entered, counting EVERY entry,
    -- excluded ones included.
    first_q as (
        select snapshot_date, contact_id, min(quarter_start) as first_quarter
        from e
        group by snapshot_date, contact_id
    ),
    t as (
        select e.*, e.quarter_start > f.first_quarter as is_repeat
        from e
        join first_q f using (snapshot_date, contact_id)
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
           count(distinct t.contact_id) filter (where t.exclusion_reason is null and not t.is_repeat)                         as entered_contacts,
           count(distinct t.contact_id) filter (where t.exclusion_reason is null and not t.is_repeat and t.is_junk_or_dq)     as now_junk_or_disqualified,
           count(distinct t.contact_id) filter (where t.exclusion_reason is null and not t.is_repeat and not t.is_junk_or_dq) as mqls,
           count(distinct t.contact_id) filter (where t.exclusion_reason is not null)                                         as excluded_contacts,
           count(distinct t.contact_id) filter (where t.exclusion_reason is null and t.is_repeat)                             as repeat_contacts
    from quarters q
    left join t
           on t.snapshot_date = q.snapshot_date
          and t.quarter_start = q.quarter_start
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
    with a as (
        select m.*,
               date_trunc('quarter', m.entered_at at time zone 'America/Chicago')::date as q
        from snap_mql_entry m
        where not m.is_internal
    ),
    first_q as (
        select snapshot_date, contact_id, min(q) as first_quarter
        from a
        group by snapshot_date, contact_id
    ),
    e as (
        select a.*
        from a
        join first_q f using (snapshot_date, contact_id)
        where a.q = f.first_quarter
          and a.exclusion_reason is null
          and a.current_lead_status is distinct from 'JUNK'
          and a.current_lead_status is distinct from 'Disqualified'
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
   set value = 'Contacts whose Lead Status entered Awaiting Sales Qualification '
               'for the first time in the quarter and is not now Junk or '
               'Disqualified. Contacts already in that status in an earlier '
               'quarter are not counted again.',
       description = 'Caption for f_mql_by_quarter / v_mql_by_quarter. Definition '
                     'per Alecia 2026-10-04: first quarter ever entered only. '
                     'Excludes the 2026-05-25 workflow misfire and the 2026-09-21 '
                     'Nurture recycle batch, which also count as earlier entries.',
       updated_at = now()
 where key = 'label_mql_by_quarter';


-- ============================== VERIFY ===============================
-- Expected on 2026-10-04: Q1 70, Q2 186, Q3 153, Q4 30.
--
-- select quarter_label, entered_contacts, now_junk_or_disqualified, mqls,
--        repeat_contacts, excluded_contacts
-- from mktg.f_mql_by_quarter()
-- where snapshot_date = '2026-10-04';
--
-- List length must still equal mqls. Expect zero rows:
-- select q.snapshot_date, q.quarter_label, q.mqls, count(c.contact_id) as listed
-- from mktg.f_mql_by_quarter() q
-- left join mktg.f_mql_contacts() c
--   on c.snapshot_date = q.snapshot_date and c.quarter_start = q.quarter_start
-- group by 1, 2, 3
-- having q.mqls <> count(c.contact_id);
