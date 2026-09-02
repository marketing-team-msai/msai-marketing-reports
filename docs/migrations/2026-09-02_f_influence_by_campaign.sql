-- =====================================================================
-- UP: f_influence_by_campaign, and v_influence_by_campaign onto one body
-- =====================================================================
-- Down version: 2026-09-02_f_influence_by_campaign.down.sql
--
-- Backs the Pipeline Influence page. Mirrors the shape of
-- f_sourced_by_program(include_amazon, close_year): the view had no
-- include_amazon parameter while every f_* object does, so a page built
-- on the view could not honour the Amazon toggle the rest of /overview
-- already carries.
--
-- Not blocked. Nothing reads v_influence_by_campaign: /overview queries
-- run_log, config_settings, f_influence_headline, f_sourced_by_program,
-- f_pipeline_model, snap_sourced_deal and v_sla_by_status, and no other
-- data page exists yet.
--
-- THE DEDUPE IS THE WHOLE POINT OF THIS FUNCTION.
--   even_split_value repeats on every contact row of a (deal, campaign)
--   pair. snap_influence holds 359 rows but only 337 distinct pairs, and
--   the 22 surplus rows carry $838,760.90. Summing rows gives
--   $12,680,992.66; collapsing to distinct pairs first gives
--   $11,842,231.76, which reconciles to compute_campaign_summary exactly.
--   per_deal_campaign below does that collapse. Do not remove it, and do
--   not add a column to this function that is summed before it.
--
-- campaign_type_filter is a FILTER, not a re-attribution. even_split_value
-- is always the deal amount over the full union of that deal's campaigns,
-- so a filtered call returns that type's share of the total rather than
-- re-splitting across the surviving campaigns. Because every (deal,
-- campaign) pair carries exactly one type, the per-type totals are
-- additive and sum back to $11,842,231.76.
--
-- Paste PASTE 1 into the Supabase SQL editor and Run. Then paste PASTE 2
-- and Run, and compare against the expected output beside each query. Do
-- not edit this file to match what you get.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres, so if any statement fails the whole paste
-- rolls back on its own.
-- =====================================================================


-- ============================== PASTE 1 ==============================

drop function if exists mktg.f_influence_by_campaign(boolean, text);

create function mktg.f_influence_by_campaign(
    include_amazon       boolean default true,
    campaign_type_filter text    default null
)
returns table (
    snapshot_date               date,
    campaign_id                 text,
    campaign_name               text,
    campaign_type               text,
    influenced_contacts         bigint,
    deals_touched               bigint,
    influenced_value_even_split numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
    with clean as (
        select *
        from snap_influence
        where not is_internal
          and not is_storefront
          and (include_amazon or not is_amazon)
          and (campaign_type_filter is null or campaign_type = campaign_type_filter)
    ),
    -- Collapse to one row per (deal, campaign) BEFORE summing.
    per_deal_campaign as (
        select distinct snapshot_date, deal_id, campaign_id, campaign_name,
               campaign_type, even_split_value
        from clean
    ),
    -- Contacts are counted on the full clean set, not the collapsed one:
    -- the contact count is the question "how many people did this campaign
    -- reach", which is contact grain, not pair grain.
    contacts_per_campaign as (
        select snapshot_date, campaign_id,
               count(distinct contact_id) as influenced_contacts
        from clean
        group by snapshot_date, campaign_id
    )
    select pdc.snapshot_date,
           pdc.campaign_id,
           pdc.campaign_name,
           pdc.campaign_type,
           cpc.influenced_contacts,
           count(distinct pdc.deal_id)  as deals_touched,
           sum(pdc.even_split_value)    as influenced_value_even_split
    from per_deal_campaign pdc
    join contacts_per_campaign cpc
      on cpc.snapshot_date = pdc.snapshot_date
     and cpc.campaign_id   = pdc.campaign_id
    group by pdc.snapshot_date, pdc.campaign_id, pdc.campaign_name,
             pdc.campaign_type, cpc.influenced_contacts
    order by pdc.snapshot_date, sum(pdc.even_split_value) desc;
$function$;


-- v_influence_by_campaign becomes the function's default-argument call.
-- Same reason as v_sourced_by_program: one body, so the view and the
-- function cannot drift the way v_influence_headline drifted from
-- f_influence_headline.
drop view if exists mktg.v_influence_by_campaign;

create view mktg.v_influence_by_campaign as
select * from mktg.f_influence_by_campaign(true, null);


grant execute on function mktg.f_influence_by_campaign(boolean, text) to authenticated;
grant select  on mktg.v_influence_by_campaign                          to authenticated;

-- ============================ END PASTE 1 ============================


-- ============================== PASTE 2 ==============================
-- Verification. Run each separately. Expected values are for snapshot
-- 2026-09-02. Any miss means run the .down.sql, not an edit to this file.

-- (a) expect exactly one row: 26 | 11842231.76
--     This is THE test. 11842231.76 means the dedupe held. 12680992.66
--     means per_deal_campaign was dropped or bypassed.
select count(*) as campaigns, sum(influenced_value_even_split) as total
  from mktg.f_influence_by_campaign(true, null);

-- (b) expect exactly one row: 26 | 11470272.17
select count(*) as campaigns, sum(influenced_value_even_split) as total
  from mktg.f_influence_by_campaign(false, null);

-- (c) expect exactly one row: 7 | 1763334.89
select count(*) as campaigns, sum(influenced_value_even_split) as total
  from mktg.f_influence_by_campaign(true, 'Event');

-- (d) expect exactly one row: 8 | 3987921.72
select count(*) as campaigns, sum(influenced_value_even_split) as total
  from mktg.f_influence_by_campaign(true, 'Content');

-- (e) expect exactly 5 rows, in this order, this is the page's default
--     ranking:
--       Campaign Influence: Vibration Soft-Launch          Content  113  81  2943669.22
--       Campaign Influence: LIVE Webinar - Why Failures...  Webinar   47  23  2111836.86
--       Campaign Influence: ICI Contact Us Web Form         Form      57  46  1213870.50
--       Campaign Influence: Video - MSAI Connect Platfor...  Video      6   3   904102.50
--       Campaign Influence: Electrical Fault Detection -...  Content    3   1   670924.83
select campaign_name, campaign_type, deals_touched, influenced_contacts,
       influenced_value_even_split
  from mktg.f_influence_by_campaign(true, null)
 limit 5;

-- (f) expect exactly one row: 26 | 11842231.76
--     the view must equal the function, since it is now the same body
select count(*) as campaigns, sum(influenced_value_even_split) as total
  from mktg.v_influence_by_campaign;

-- ============================ END PASTE 2 ============================
