-- =====================================================================
-- DOWN: revert v_ad_performance to the pre-2026-09-15 whole-window shape
-- =====================================================================
-- Up version: 2026-09-15_v_ad_performance_metric_date.sql
--
-- Safe to run. mktg.snap_ad_source is untouched either direction - this
-- only changes how the view aggregates rows that already exist. Nothing
-- is lost: the full metric_date detail stays in snap_ad_source and can be
-- re-exposed at any time by re-applying the up migration.
--
-- Restores the exact GROUP BY the view had before 2026-09-15, i.e. spend
-- etc. summed across the WHOLE trailing window per snapshot_date, with no
-- metric_date column. Do this only if the wider per-snapshot-date row
-- count (see the up migration's header) turns out to be a real problem
-- for a consumer before that consumer is ready to page through
-- metric_date instead.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres.
-- =====================================================================

drop view if exists mktg.v_ad_performance;

create view mktg.v_ad_performance as
select
    snapshot_date,
    is_paid,
    source,
    account,
    sum(clicks)      as clicks,
    sum(impressions) as impressions,
    sum(spend)       as spend,
    sum(conversions) as conversions
from mktg.snap_ad_source
group by snapshot_date, is_paid, source, account;

grant select on mktg.v_ad_performance to authenticated;

comment on view mktg.v_ad_performance is
  'Ad spend/clicks/impressions/conversions per (source, account), summed '
  'across the ENTIRE snap_ad_source trailing window for that '
  'snapshot_date - not a day-by-day trend. metric_date detail exists in '
  'snap_ad_source but is not exposed here. Returns every snapshot_date; '
  'filter server-side.';


-- ---------------------------------------------------------------------
-- Verification.
-- ---------------------------------------------------------------------

-- expected: 1 (the view exists)
select count(*) as views_present
  from pg_views
 where schemaname = 'mktg' and viewname = 'v_ad_performance';

-- expected: metric_date is NOT in this list
select column_name
  from information_schema.columns
 where table_schema = 'mktg' and table_name = 'v_ad_performance'
 order by ordinal_position;

-- expected, snapshot 2026-09-15: one row per source/account, spend summed
-- across the whole window - same totals as PASTE 2.3 in the up migration,
-- just collapsed back to one row per source instead of one per day.
select source, account, is_paid, spend
from mktg.v_ad_performance
where snapshot_date = '2026-09-15'
order by spend desc;
