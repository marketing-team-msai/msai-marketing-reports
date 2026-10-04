-- =====================================================================
-- DOWN: remove Marketing Qualified Leads by quarter
-- =====================================================================
-- Reverses 2026-10-04_mql_by_quarter.sql. Drops the table and its data;
-- the data is re-derivable from HubSpot history with a full
-- `sync_to_mktg.py --only mql --mql-full` run.

drop view if exists mktg.v_mql_by_quarter;
drop function if exists mktg.f_mql_by_quarter();
drop table if exists mktg.snap_mql_entry;
delete from mktg.config_settings where key = 'label_mql_by_quarter';
