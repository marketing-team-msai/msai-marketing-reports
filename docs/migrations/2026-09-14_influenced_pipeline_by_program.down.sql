-- =====================================================================
-- DOWN: remove the influenced-pipeline objects and their labels
-- =====================================================================
-- Up version: 2026-09-14_influenced_pipeline_by_program.sql
--
-- Safe to run. Everything here is derived: the three functions and two
-- views read snap_influence, snap_sourced_deal and config_program_keywords
-- and store nothing. No snap_* table is touched, no history is lost, and
-- re-applying the up migration reproduces every figure for every snapshot.
--
-- Nothing in the ETL writes or reads any of this, so a sync run is
-- unaffected either way. f_sourced_by_program, f_influence_by_campaign,
-- snap_influence.even_split_value and is_single_program were never
-- modified by the up migration, so there is nothing to restore.
--
-- ORDER MATTERS. v_influenced_deal_detail and the three functions all
-- read v_deal_program, so v_deal_program goes last. Dropping it first
-- would fail on the dependency, and adding `cascade` would silently take
-- the dependants with it.
--
-- The label rows are deleted rather than left behind. An orphan
-- label_influenced_by_program in config_settings would read as live
-- policy to the next person, and the caption it carries would be
-- describing a view that no longer exists.
--
-- label_single_program is deleted with the rest. If the terminology
-- change is being KEPT while these objects are dropped, remove that one
-- key from the delete below before running.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres.
-- =====================================================================

drop view if exists mktg.v_influenced_deal_detail;

drop function if exists mktg.f_influenced_by_combination(boolean);
drop function if exists mktg.f_influenced_by_program(boolean);
drop function if exists mktg.f_influenced_pipeline(boolean);

drop view if exists mktg.v_deal_program;

delete from mktg.config_settings
 where key in ('label_single_program',
               'label_influenced_by_program',
               'label_allocated_even_split',
               'label_influenced_scope');


-- ---------------------------------------------------------------------
-- Verification. Expected: 0, 0, 0, and then the untouched objects still
-- present - expected 1, 1.
-- ---------------------------------------------------------------------
select count(*) as views_left
  from pg_views
 where schemaname = 'mktg'
   and viewname in ('v_deal_program', 'v_influenced_deal_detail');

select count(*) as functions_left
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'mktg'
   and p.proname in ('f_influenced_pipeline', 'f_influenced_by_program',
                     'f_influenced_by_combination');

select count(*) as label_rows_left
  from mktg.config_settings
 where key in ('label_single_program', 'label_influenced_by_program',
               'label_allocated_even_split', 'label_influenced_scope');

-- Untouched by either direction. Expected 1 and 1.
select count(*) as f_sourced_by_program_still_there
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'mktg' and p.proname = 'f_sourced_by_program';

select count(*) as f_influence_by_campaign_still_there
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'mktg' and p.proname = 'f_influence_by_campaign';
