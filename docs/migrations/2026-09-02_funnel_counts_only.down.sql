-- =====================================================================
-- DOWN 2/3: restore the dollar column on the contacts-by-stage funnel
-- =====================================================================
-- Reverses 2026-09-02_funnel_counts_only.sql.
--
-- Definitions below are copied verbatim from docs/schema.sql as captured
-- on 2026-09-02, including the grant that DROP discarded.
--
-- =====================================================================
-- NOT FULLY REVERSIBLE. READ THIS BEFORE RUNNING.
-- =====================================================================
-- This restores the influenced_value COLUMN. It does NOT restore the
-- VALUES. Every row comes back NULL.
--
-- ALTER TABLE DROP COLUMN discards the data with the column. There is one
-- snapshot in this database, 2026-09-02, and its values were the
-- known-wrong ones that caused the $1,129,524.90 double count, so nothing
-- of value is lost. But the loss is real and it is one-way from SQL.
--
-- The only way to repopulate is to revert the sync_to_mktg.py change that
-- shipped with the up migration, restoring "influenced_value" to
-- COLUMNS["snap_sourced_contact"] and to rows_sourced_contact(), and then
-- re-run the netnew sync against HubSpot:
--
--     python sync_to_mktg.py --only netnew
--
-- That recomputes the column from live HubSpot data, which will not match
-- the 2026-09-02 values exactly because HubSpot has moved on. Note the
-- CLAUDE.md gotcha: an --only run overwrites the whole-day run_log
-- summary, so re-run all three afterwards.
--
-- Until that re-run happens, f_sourced_contacts_by_stage returns NULL in
-- influenced_value for every stage, not 0 and not the prior figures.
--
-- WARNING: restoring this restores the BUG. sum(influenced_value) across
-- contacts double counts any deal touched by more than one sourced
-- contact. It overstated by $1,129,524.90 on the 2026-09-02 snapshot.
-- =====================================================================


-- ============================== PASTE 1 ==============================

-- 1. Column back, empty.
alter table mktg.snap_sourced_contact
  add column if not exists influenced_value numeric;

-- 2. Function back at the prior signature. The up migration dropped the
--    old one, so this is a create, and the return type differs from what
--    is currently deployed, so it must be dropped first.
drop function if exists mktg.f_sourced_contacts_by_stage(boolean);

create function mktg.f_sourced_contacts_by_stage(
    include_amazon boolean default true
)
returns table (
    snapshot_date    date,
    lifecycle_stage  text,
    sourced_contacts bigint,
    influenced_value numeric
)
language sql
stable
set search_path to 'mktg', 'public', 'pg_temp'
as $function$
    select snapshot_date, lifecycle_stage, count(*), sum(influenced_value)
    from snap_sourced_contact
    where not is_internal and (include_amazon or not is_amazon)
    group by snapshot_date, lifecycle_stage;
$function$;

-- 3. View back.
create or replace view mktg.v_sourced_contacts_by_stage as
 SELECT snapshot_date,
    lifecycle_stage,
    count(*) AS sourced_contacts,
    sum(influenced_value) AS influenced_value
   FROM mktg.snap_sourced_contact
  WHERE NOT is_internal
  GROUP BY snapshot_date, lifecycle_stage;

-- 4. Re-grant.
grant execute on function mktg.f_sourced_contacts_by_stage(boolean) to authenticated;
grant select  on mktg.v_sourced_contacts_by_stage                   to authenticated;

-- ============================ END PASTE 1 ============================


-- ============================== PASTE 2 ==============================
-- Verification. Run separately, after PASTE 1.

-- (a) expect exactly one row, one column, value 1
select count(*) as should_be_one
  from information_schema.columns
 where table_schema = 'mktg'
   and table_name   = 'snap_sourced_contact'
   and column_name  = 'influenced_value';

-- (b) expect 8 rows. sourced_contacts matches the up migration's numbers
--     (lead 2669, marketingqualifiedlead 1152, 157687207 218,
--      opportunity 83, customer 81, salesqualifiedlead 72, other 3,
--      evangelist 1) and influenced_value is NULL on every row.
--     NULL is the expected result. It is not a failure of this rollback,
--     it is the data loss documented in the header.
select lifecycle_stage, sourced_contacts, influenced_value
  from mktg.f_sourced_contacts_by_stage(true)
 order by sourced_contacts desc;

-- (c) expect exactly one row, one column, value 1
select count(*) as should_be_one
  from information_schema.views
 where table_schema = 'mktg'
   and table_name   = 'v_sourced_contacts_by_stage';

-- ============================ END PASTE 2 ============================
