-- =====================================================================
-- DOWN: remove the MQL contact list
-- =====================================================================
-- Reverses 2026-10-04_mql_contact_list.sql. Drop the columns only after
-- reverting sync_to_mktg.py, or the next run's writes will fail.

drop view if exists mktg.v_mql_contacts;
drop function if exists mktg.f_mql_contacts();
alter table mktg.snap_mql_entry
  drop column if exists contact_name,
  drop column if exists company_name,
  drop column if exists owner_name;
