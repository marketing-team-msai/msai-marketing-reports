-- =====================================================================
-- mktg: contacts-by-stage funnel becomes counts only
-- =====================================================================
-- NOT APPLIED.
--
-- Ratified 2026-09-02. The funnel answers "where do marketing-sourced
-- contacts sit", which is a count question. The dollar column on it was
-- overstating by $1,129,524.90.
--
-- Why the column goes rather than gets fixed
--   snap_sourced_contact.influenced_value is the total amount of the Net
--   New deals a contact is associated with. Two contacts on one deal each
--   carry that deal's full amount, so summing across contacts counts the
--   deal twice. 12 deals are carried by more than one sourced contact,
--   worth $1,129,524.90 of double count, none of them Amazon or Galco.
--   sync_to_mktg.py said de-duplication was "the view's job"; the view
--   never did it, and could not, because the table carries no deal_id.
--
--   An even-split dollar column would fix the number while keeping the
--   shape that caused it. Removing the column removes the trap: no ETL
--   change, no new column, no attribution model to approve. The funnel is
--   already captioned directional-only because HubSpot auto-advances and
--   skips stages, so a precise dollar on an imprecise funnel was false
--   precision either way.
--
-- Safe to apply now: nothing reads either object. /overview does not
-- query them and no contacts-by-stage page exists.
--
-- Order matters. The view depends on the column and the function depends
-- on the table, so both come down before the column does.
--
-- Run inside an explicit transaction. Apply, run the verification block,
-- and only commit if every figure matches. If one misses, roll back and
-- report rather than adjusting the SQL to match the output.
-- =====================================================================

begin;


-- ---------------------------------------------------------------------
-- 1. Drop the duplicate view outright
-- ---------------------------------------------------------------------
-- Unread, and a second body answering the same question as the function.
-- That pattern is what let v_influence_headline drift.
drop view if exists mktg.v_sourced_contacts_by_stage;


-- ---------------------------------------------------------------------
-- 2. f_sourced_contacts_by_stage, without the dollar column
-- ---------------------------------------------------------------------
-- Dropping a column changes the return type, so create-or-replace would
-- leave a second overload behind and Postgres would then throw "could
-- not choose the best candidate function".
drop function if exists mktg.f_sourced_contacts_by_stage(boolean);


-- ---------------------------------------------------------------------
-- 3. Remove the column so no future consumer can pick it up
-- ---------------------------------------------------------------------
alter table mktg.snap_sourced_contact drop column if exists influenced_value;


-- ---------------------------------------------------------------------
-- 4. Recreate the function, counts only
-- ---------------------------------------------------------------------
create function mktg.f_sourced_contacts_by_stage(
    include_amazon boolean default true
)
returns table (
    snapshot_date   date,
    lifecycle_stage text,
    sourced_contacts bigint
)
language sql
stable
set search_path to 'mktg', 'public', 'pg_temp'
as $function$
    select snapshot_date, lifecycle_stage, count(*)
    from snap_sourced_contact
    where not is_internal and (include_amazon or not is_amazon)
    group by snapshot_date, lifecycle_stage;
$function$;


-- ---------------------------------------------------------------------
-- 5. Re-grant what the drop discarded
-- ---------------------------------------------------------------------
grant execute on function mktg.f_sourced_contacts_by_stage(boolean) to authenticated;


-- =====================================================================
-- VERIFICATION. Expected values are for snapshot 2026-09-02. Any miss
-- means rollback, not an edit to the SQL.
-- =====================================================================

-- (a) counts unchanged, no dollar column in the result
select lifecycle_stage, sourced_contacts
  from mktg.f_sourced_contacts_by_stage(true)
 order by sourced_contacts desc;
--   lead                    2669
--   marketingqualifiedlead  1152
--   157687207                218
--   opportunity               83
--   customer                  81
--   salesqualifiedlead        72
--   other                      3
--   evangelist                 1
--   8 rows, 4279 contacts total

-- (b) the column is gone
select count(*) from information_schema.columns
 where table_schema = 'mktg'
   and table_name   = 'snap_sourced_contact'
   and column_name  = 'influenced_value';
--   0

-- (c) the view is gone
select count(*) from information_schema.views
 where table_schema = 'mktg'
   and table_name   = 'v_sourced_contacts_by_stage';
--   0

-- commit;
-- rollback;


-- =====================================================================
-- Companion change in sync_to_mktg.py, apply together
-- =====================================================================
-- The ETL must stop writing the column in the same change, or the next
-- daily run fails on an unknown column.
--
--   COLUMNS["snap_sourced_contact"]  drop "influenced_value"
--   rows_sourced_contact()           drop the "influenced_value" key and
--                                    the docstring paragraph describing
--                                    de-duplication as the view's job
--
-- This does NOT affect the standalone Excel run. generate_report.py has
-- its own influenced_value at generate_report.py:310, computed as
-- sum(amount) over a set of distinct influenced deal ids. That one is
-- deal-grain, already deduplicated, feeds the workbook and push_history,
-- and never reads snap_sourced_contact.
