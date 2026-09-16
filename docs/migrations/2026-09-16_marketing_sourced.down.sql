-- =====================================================================
-- DOWN: remove the Marketing Sourced objects, drop the 7 new
--       snap_sourced_deal columns, restore config_settings
-- =====================================================================
-- Reverts 2026-09-16_marketing_sourced.sql.
--
-- Run this BEFORE reverting generate_netnew_report.py's dealtype /
-- lead_source pull and LEAD_SOURCE_BUCKET, same discipline as every
-- other migration pair here: revert the SQL mechanism first, then the
-- Python source of truth, so nothing reads a half-migrated state.
--
-- Dropping the 7 columns is a real data loss for any already-written
-- snapshot_date's sourcing_status/marketing_lead_sources/etc - but
-- those columns did not exist before this migration, so nothing else
-- can depend on them, and the next run of sync_to_mktg.py (once its
-- Python side is also reverted) will simply stop writing them.
-- =====================================================================

drop function if exists mktg.f_marketing_sourced_by_program(boolean);
drop view     if exists mktg.v_marketing_sourced_by_program;

drop function if exists mktg.f_marketing_sourced_by_lead_source(boolean);
drop view     if exists mktg.v_marketing_sourced_by_lead_source;

drop function if exists mktg.f_marketing_sourced(boolean, integer);
drop view     if exists mktg.v_marketing_sourced;

delete from mktg.config_settings
 where key in ('label_marketing_sourced', 'label_marketing_sourced_scope');

alter table mktg.snap_sourced_deal
  drop column if exists sourcing_status,
  drop column if exists marketing_sourced,
  drop column if exists primary_lead_source,
  drop column if exists marketing_lead_sources,
  drop column if exists has_marketing_lead_source,
  drop column if exists is_new_business,
  drop column if exists deal_type;

-- config_lead_source_bucket is left in place (harmless once nothing
-- reads it) rather than dropped - same convention as
-- config_campaign_type_program in the 2026-09-15 down migration. Drop
-- it by hand only if you're certain nothing else has come to depend on
-- it.
