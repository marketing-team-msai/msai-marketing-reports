-- =====================================================================
-- DOWN: reverses 2026-09-14_revenue_split.sql
-- =====================================================================
-- Reverts the Overview/Influence "Marketing contribution to the 2026
-- company revenue target" card to marketing-only figures (the frontend
-- change would need reverting separately - this only removes the backing
-- data).
-- =====================================================================

drop view if exists mktg.v_revenue_split;
drop function if exists mktg.f_revenue_split(integer, boolean);
drop table if exists mktg.snap_all_deals;
