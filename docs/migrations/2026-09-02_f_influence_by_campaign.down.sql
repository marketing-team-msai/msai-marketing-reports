-- =====================================================================
-- DOWN: remove f_influence_by_campaign, restore the standalone view
-- =====================================================================
-- Reverses 2026-09-02_f_influence_by_campaign.sql.
--
-- The view definition below is copied verbatim from docs/schema.sql as
-- captured on 2026-09-02, including the grant that DROP discarded.
--
-- Fully reversible. No data is touched, only definitions.
--
-- Note: the restored view is CORRECT. It has the per_deal_campaign
-- collapse and returns $11,842,231.76. The only thing it lacks is the
-- include_amazon and campaign_type_filter parameters. So rolling back
-- costs the Pipeline Influence page its filters, not its accuracy.
-- =====================================================================


-- ============================== PASTE 1 ==============================

drop view if exists mktg.v_influence_by_campaign;

create view mktg.v_influence_by_campaign as
 WITH clean AS (
         SELECT snap_influence.snapshot_date,
            snap_influence.deal_id,
            snap_influence.contact_id,
            snap_influence.campaign_id,
            snap_influence.campaign_name,
            snap_influence.campaign_type,
            snap_influence.deal_name,
            snap_influence.company_name,
            snap_influence.pipeline,
            snap_influence.stage,
            snap_influence.amount_home,
            snap_influence.is_closed,
            snap_influence.is_won,
            snap_influence.create_date,
            snap_influence.close_date,
            snap_influence.even_split_value,
            snap_influence.is_amazon,
            snap_influence.is_galco,
            snap_influence.is_internal,
            snap_influence.is_storefront,
            snap_influence.is_seeded
           FROM mktg.snap_influence
          WHERE NOT snap_influence.is_internal AND NOT snap_influence.is_storefront
        ), per_deal_campaign AS (
         SELECT DISTINCT clean.snapshot_date,
            clean.deal_id,
            clean.campaign_id,
            clean.campaign_name,
            clean.campaign_type,
            clean.even_split_value
           FROM clean
        ), contacts_per_campaign AS (
         SELECT clean.snapshot_date,
            clean.campaign_id,
            count(DISTINCT clean.contact_id) AS influenced_contacts
           FROM clean
          GROUP BY clean.snapshot_date, clean.campaign_id
        )
 SELECT pdc.snapshot_date,
    pdc.campaign_id,
    pdc.campaign_name,
    pdc.campaign_type,
    cpc.influenced_contacts,
    count(DISTINCT pdc.deal_id) AS deals_touched,
    sum(pdc.even_split_value) AS influenced_value_even_split
   FROM per_deal_campaign pdc
     JOIN contacts_per_campaign cpc ON cpc.snapshot_date = pdc.snapshot_date AND cpc.campaign_id = pdc.campaign_id
  GROUP BY pdc.snapshot_date, pdc.campaign_id, pdc.campaign_name, pdc.campaign_type, cpc.influenced_contacts;

drop function if exists mktg.f_influence_by_campaign(boolean, text);

grant select on mktg.v_influence_by_campaign to authenticated;

-- ============================ END PASTE 1 ============================


-- ============================== PASTE 2 ==============================
-- Verification. Run each separately.

-- (a) expect exactly one row: 26 | 11842231.76
select count(*) as campaigns, sum(influenced_value_even_split) as total
  from mktg.v_influence_by_campaign;

-- (b) expect exactly one row, one column, value 0
select count(*) as should_be_zero
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'mktg' and p.proname = 'f_influence_by_campaign';

-- ============================ END PASTE 2 ============================
