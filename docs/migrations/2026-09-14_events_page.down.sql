-- =====================================================================
-- DOWN: reverses 2026-09-14_events_page.sql
-- =====================================================================
-- Drops the view/function before the tables they read, and the tables in
-- dependent order (snap_event_funnel and event_cost reference event, so
-- they go first). Policies and grants are dropped automatically with
-- their tables; nothing to undo there separately.
--
-- This deletes all Events page data, including anything entered through
-- the app (budget/actual cost, any events added via the app's "Add Event"
-- form). Back up mktg.event and mktg.event_cost first if that data
-- matters.
-- =====================================================================

drop view if exists mktg.v_event_roi;
drop function if exists mktg.f_event_roi();
drop function if exists mktg.is_event_editor();

drop table if exists mktg.snap_event_funnel;
drop table if exists mktg.event_cost;
drop table if exists mktg.event_hubspot_list;
drop table if exists mktg.event;
drop table if exists mktg.event_editor;
