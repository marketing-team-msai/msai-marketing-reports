-- =====================================================================
-- mktg schema - generated dump of every view and function
-- =====================================================================
-- GENERATED FILE. Do not hand-edit. Refresh it whenever a migration
-- lands, so a session can read the definitions here instead of asking
-- for them to be run by hand. Regenerate by running this in the
-- Supabase SQL editor and saving the result over docs/schema.sql:
--
--   select 'view: '||viewname as obj,
--          pg_get_viewdef(('mktg.'||viewname)::regclass, true) as def
--     from pg_views where schemaname='mktg'
--   union all
--   select 'func: '||p.proname, pg_get_functiondef(p.oid)
--     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='mktg'
--   order by 1;
--
-- Tables are NOT in here. The column contract for the snap_* tables is
-- COLUMNS in sync_to_mktg.py, which --check-schema diffs against the
-- live schema.
-- =====================================================================

-- ============================== FUNCTIONS ==============================

-- ---------------------------------------------------------------------
-- f_influence_headline
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_influence_headline(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, total_deals bigint, deals_clean bigint, influenced_pipeline numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with clean as (
        select distinct snapshot_date, deal_id, amount_home
        from snap_influence
        where not is_internal and not is_storefront
          and (include_amazon or not is_amazon)
    )
    select
        snapshot_date,
        count(distinct deal_id) as total_deals,
        count(distinct deal_id) as deals_clean,
        sum(amount_home)        as influenced_pipeline
    from clean
    group by snapshot_date;
$function$

-- ---------------------------------------------------------------------
-- f_pipeline_model
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_pipeline_model(include_amazon boolean DEFAULT true, close_year integer DEFAULT NULL::integer)
 RETURNS TABLE(snapshot_date date, sourced_pipeline numeric, target_2027 numeric, assigned_wr numeric, qualified_pipeline_needed_2027 numeric, sourced_share_of_need numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with cfg as (
        select
          max(case when key='target_2027' then value::numeric end)          as target_2027,
          max(case when key='assigned_win_rate_2027' then value::numeric end) as assigned_wr
        from config_settings
    ),
    sourced as (
        select snapshot_date, sum(sourced_pipeline) as sourced_pipeline
        from f_sourced_by_program(include_amazon, close_year) group by snapshot_date
    )
    select
        s.snapshot_date, s.sourced_pipeline, c.target_2027, c.assigned_wr,
        (c.target_2027 / nullif(c.assigned_wr,0)),
        s.sourced_pipeline / nullif(c.target_2027 / nullif(c.assigned_wr,0), 0)
    from sourced s cross join cfg c;
$function$

-- ---------------------------------------------------------------------
-- f_sourced_by_program
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_sourced_by_program(include_amazon boolean DEFAULT true, close_year integer DEFAULT NULL::integer)
 RETURNS TABLE(snapshot_date date, program text, sourced_deals bigint, sourced_pipeline numeric, sourced_won numeric, won_deals bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    select
        snapshot_date,
        coalesce(program, '(unclassified)'),
        count(*) filter (where is_single_program),
        sum(amount_home) filter (where is_single_program),
        sum(amount_home) filter (where is_single_program and is_closed_won),
        count(*) filter (where is_single_program and is_closed_won)
    from snap_sourced_deal
    where (include_amazon or not is_amazon)
      and (close_year is null or extract(year from close_date) = close_year)
    group by snapshot_date, coalesce(program, '(unclassified)');
$function$

-- ---------------------------------------------------------------------
-- f_sourced_contacts_by_stage
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_sourced_contacts_by_stage(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, lifecycle_stage text, sourced_contacts bigint, influenced_value numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg', 'public', 'pg_temp'
AS $function$
    select snapshot_date, lifecycle_stage, count(*), sum(influenced_value)
    from snap_sourced_contact
    where not is_internal and (include_amazon or not is_amazon)
    group by snapshot_date, lifecycle_stage;
$function$

-- ================================ VIEWS ================================

-- ---------------------------------------------------------------------
-- v_ad_performance
-- ---------------------------------------------------------------------
create or replace view mktg.v_ad_performance as
 SELECT snapshot_date,
    is_paid,
    source,
    account,
    sum(clicks) AS clicks,
    sum(impressions) AS impressions,
    sum(spend) AS spend,
    sum(conversions) AS conversions
   FROM mktg.snap_ad_source
  GROUP BY snapshot_date, is_paid, source, account;

-- ---------------------------------------------------------------------
-- v_influence_by_campaign
-- ---------------------------------------------------------------------
create or replace view mktg.v_influence_by_campaign as
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

-- ---------------------------------------------------------------------
-- v_influence_headline
-- ---------------------------------------------------------------------
create or replace view mktg.v_influence_headline as
 SELECT s.snapshot_date,
    count(DISTINCT s.deal_id) AS total_deals,
    count(DISTINCT s.deal_id) FILTER (WHERE NOT s.is_internal) AS deals_clean,
    sum(distinct_amount.amount_home) AS influenced_pipeline
   FROM mktg.snap_influence s
     JOIN LATERAL ( SELECT DISTINCT ON (s2.deal_id) s2.amount_home
           FROM mktg.snap_influence s2
          WHERE s2.snapshot_date = s.snapshot_date AND s2.deal_id = s.deal_id) distinct_amount ON true
  WHERE NOT s.is_internal AND NOT s.is_storefront
  GROUP BY s.snapshot_date;

-- ---------------------------------------------------------------------
-- v_latest_snapshot
-- ---------------------------------------------------------------------
create or replace view mktg.v_latest_snapshot as
 SELECT max(snapshot_date) AS snapshot_date
   FROM mktg.run_log
  WHERE status = 'ok'::text;

-- ---------------------------------------------------------------------
-- v_sla_by_owner
-- ---------------------------------------------------------------------
create or replace view mktg.v_sla_by_owner as
 SELECT snapshot_date,
    owner_name,
    count(*) AS contacts_worked,
    count(*) FILTER (WHERE over_sla) AS over_sla,
    round(avg(days_in_lifecycle_stage), 1) AS avg_days_in_stage
   FROM mktg.snap_lead_sla
  GROUP BY snapshot_date, owner_name;

-- ---------------------------------------------------------------------
-- v_sla_by_status
-- ---------------------------------------------------------------------
create or replace view mktg.v_sla_by_status as
 SELECT snapshot_date,
    lead_status,
    count(*) AS total_contacts,
    count(*) FILTER (WHERE over_sla) AS over_sla,
    round(100.0 * count(*) FILTER (WHERE over_sla)::numeric / NULLIF(count(*), 0)::numeric, 1) AS pct_over_sla,
    round(avg(days_in_status), 1) AS avg_days_in_status,
    round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (days_in_status::double precision))::numeric, 1) AS median_days_in_status
   FROM mktg.snap_lead_sla
  GROUP BY snapshot_date, lead_status;

-- ---------------------------------------------------------------------
-- v_sourced_by_program
-- ---------------------------------------------------------------------
create or replace view mktg.v_sourced_by_program as
 SELECT snapshot_date,
    COALESCE(program, '(unclassified)'::text) AS program,
    count(*) FILTER (WHERE is_single_program) AS sourced_deals,
    sum(amount_home) FILTER (WHERE is_single_program) AS sourced_pipeline,
    sum(amount_home) FILTER (WHERE is_single_program AND is_closed_won) AS sourced_won,
    count(*) FILTER (WHERE is_single_program AND is_closed_won) AS won_deals
   FROM mktg.snap_sourced_deal
  GROUP BY snapshot_date, (COALESCE(program, '(unclassified)'::text));

-- ---------------------------------------------------------------------
-- v_sourced_contacts_by_stage
-- ---------------------------------------------------------------------
create or replace view mktg.v_sourced_contacts_by_stage as
 SELECT snapshot_date,
    lifecycle_stage,
    count(*) AS sourced_contacts,
    sum(influenced_value) AS influenced_value
   FROM mktg.snap_sourced_contact
  WHERE NOT is_internal
  GROUP BY snapshot_date, lifecycle_stage;
