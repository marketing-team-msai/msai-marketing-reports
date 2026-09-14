-- =====================================================================
-- Window anchor moved from 2025-06-01 to 2026-01-01: snapshot cleanup
-- =====================================================================
-- Down version: 2026-09-14_window_anchor_2026_cleanup.down.sql (none -
-- this deletes rows and cannot be reversed; re-running the sync only
-- rewrites in-window rows.)
--
-- WHY
-- mktg.config_settings.window_anchor_netnew said 2026-01-01 while the ETL
-- pulled from 2025-06-01, so every dashboard caption reading "Deals created
-- since January 1, 2026" was false and every headline was computed over
-- roughly twice the population the label implied. The ETL now uses
-- 2026-01-01 (DEALS_CREATED_SINCE in the workflow, and the module defaults
-- in generate_report.py / generate_netnew_report.py).
--
-- sync_to_mktg.py upserts and never deletes, so the 2026-09-14 snapshot
-- still holds the rows from the earlier, wider run. They are stale: their
-- deals are outside the window the pipeline now reports on.
--
-- YOU MAY NOT NEED THIS AT ALL
-- Tomorrow's scheduled run writes a NEW snapshot_date with only in-window
-- rows, and v_latest_snapshot points at the newest date. So the dashboard
-- corrects itself on the next run whether or not you run this. Run it only
-- if you want the 2026-09-14 snapshot itself to be clean.
--
-- Counts verified live on 2026-09-14 before writing this file:
--   snap_sourced_deal      867 rows -> 436 in-window, 431 to delete
--   snap_influence         422 rows -> 291 in-window, 131 to delete
--   snap_sourced_contact  4426 rows -> 4143 in-window, 283 to delete
--   snap_lead_sla is not window-scoped and is untouched.
-- =====================================================================


-- PASTE 1: look before you delete. Expect 431 / 131 / 283.
select 'snap_sourced_deal' as table_name, count(*) as to_delete
  from mktg.snap_sourced_deal
 where snapshot_date = '2026-09-14' and create_date < '2026-01-01'
union all
select 'snap_influence', count(*)
  from mktg.snap_influence
 where snapshot_date = '2026-09-14' and create_date < '2026-01-01'
union all
select 'snap_sourced_contact', count(*)
  from mktg.snap_sourced_contact
 where snapshot_date = '2026-09-14' and create_date < '2026-01-01';


-- PASTE 2: the cleanup, today's snapshot only.
begin;

delete from mktg.snap_sourced_deal
 where snapshot_date = '2026-09-14' and create_date < '2026-01-01';

delete from mktg.snap_influence
 where snapshot_date = '2026-09-14' and create_date < '2026-01-01';

delete from mktg.snap_sourced_contact
 where snapshot_date = '2026-09-14' and create_date < '2026-01-01';

commit;


-- PASTE 3: confirm. Expect 436 / 291 / 4143, and earliest create_date
-- 2026-01-01 or later in all three.
select 'snap_sourced_deal' as table_name, count(*) as rows_now,
       min(create_date) as earliest
  from mktg.snap_sourced_deal where snapshot_date = '2026-09-14'
union all
select 'snap_influence', count(*), min(create_date)
  from mktg.snap_influence where snapshot_date = '2026-09-14'
union all
select 'snap_sourced_contact', count(*), min(create_date)
  from mktg.snap_sourced_contact where snapshot_date = '2026-09-14';


-- =====================================================================
-- OPTIONAL: every earlier snapshot too (2026-09-02 .. 2026-09-13)
-- =====================================================================
-- Those snapshots were accurate records of the OLD definition. Deleting
-- from them loses that record, but it makes the daily series comparable:
-- otherwise any trend chart shows a step down on the day the window
-- changed, which reads like a business event and is not one.
--
-- Decide deliberately. Nothing else depends on this.
--
-- begin;
-- delete from mktg.snap_sourced_deal    where create_date < '2026-01-01';
-- delete from mktg.snap_influence       where create_date < '2026-01-01';
-- delete from mktg.snap_sourced_contact where create_date < '2026-01-01';
-- commit;
--
-- run_log_reports.metrics on those earlier dates is a display cache written
-- at run time and will still hold the old figures. It is not recomputed by
-- the deletes above.
