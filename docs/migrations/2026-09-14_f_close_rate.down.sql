-- =====================================================================
-- DOWN: remove f_close_rate, v_close_rate and their config rows
-- =====================================================================
-- Up version: 2026-09-14_f_close_rate.sql
--
-- Safe to run. Nothing writes anything this removes, and no snap_* table
-- is touched: f_close_rate reads snap_sourced_deal and stores nothing, so
-- reversing it loses no data and no history. Every rate it returned can
-- be recomputed for any snapshot by re-applying the up migration.
--
-- The view goes first. Dropping the function while the view still selects
-- from it would fail on the dependency, and `drop function ... cascade`
-- would take the view with it silently, which is the kind of quiet
-- collateral this repo would rather not have.
--
-- mktg.snap_close_rate is NOT touched here either. It was already empty
-- and unwritten before this migration and it stays that way; the up
-- version only documented it as superseded.
--
-- The config rows are deleted rather than left behind. They exist only to
-- feed this function, and an orphan close_rate_min_closed sitting in
-- config_settings would read as live policy to the next person.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres.
-- =====================================================================

drop view if exists mktg.v_close_rate;

drop function if exists mktg.f_close_rate(integer);

delete from mktg.config_settings
 where key in ('close_rate_min_closed', 'close_rate_population');


-- ---------------------------------------------------------------------
-- Verification. Expected: 0, 0, 0.
-- ---------------------------------------------------------------------
select count(*) as views_left
  from pg_views
 where schemaname = 'mktg' and viewname = 'v_close_rate';

select count(*) as functions_left
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'mktg' and p.proname = 'f_close_rate';

select count(*) as config_rows_left
  from mktg.config_settings
 where key in ('close_rate_min_closed', 'close_rate_population');
