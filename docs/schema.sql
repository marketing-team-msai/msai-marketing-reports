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
--
-- Captured after the 2026-09-02 migrations. v_influence_headline and
-- v_sourced_contacts_by_stage were dropped; see docs/migrations/.
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
          max(case when key='target_2027' then value::numeric end)            as target_2027,
          max(case when key='assigned_win_rate_2027' then value::numeric end) as assigned_wr
        from config_settings
    ),
    sourced as (
        select snapshot_date, sum(sourced_pipeline) as sourced_pipeline
        from f_sourced_by_program(include_amazon, close_year)
        where row_type = 'program'
        group by snapshot_date
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
 RETURNS TABLE(snapshot_date date, row_type text, program text, measurement text, sourced_deals bigint, sourced_pipeline numeric, sourced_won numeric, won_deals bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with scope as (
        select *
        from snap_sourced_deal
        where (include_amazon or not is_amazon)
          and (close_year is null or extract(year from close_date) = close_year)
    ),
    days as (
        select distinct snapshot_date from snap_sourced_deal
    ),
    programs (program, sort_order) as (
        values ('Content & Technology', 1),
               ('Events',               2),
               ('Advertising',          3),
               ('PR & Brand',           4)
    ),
    unmeasured as (
        select coalesce(
                 (select array(select trim(x)
                                 from unnest(string_to_array(value, ',')) as x)
                    from config_settings
                   where key = 'unmeasured_programs'),
                 '{}'::text[]) as names
    ),
    program_rows as (
        select d.snapshot_date,
               'program'::text as row_type,
               p.program,
               case when p.program = any(u.names)
                    then 'not_measured' else 'measured' end as measurement,
               count(s.deal_id)                                              as sourced_deals,
               coalesce(sum(s.amount_home), 0)                               as sourced_pipeline,
               coalesce(sum(s.amount_home) filter (where s.is_closed_won), 0) as sourced_won,
               count(s.deal_id) filter (where s.is_closed_won)               as won_deals,
               p.sort_order
        from days d
        cross join programs p
        cross join unmeasured u
        left join scope s
               on s.snapshot_date = d.snapshot_date
              and s.is_single_program
              and s.program = p.program
        group by d.snapshot_date, p.program, p.sort_order, u.names
    ),
    reconciling_rows as (
        select d.snapshot_date,
               'reconciling'::text,
               '(multi)'::text,
               'measured'::text,
               count(s.deal_id),
               coalesce(sum(s.amount_home), 0),
               coalesce(sum(s.amount_home) filter (where s.is_closed_won), 0),
               count(s.deal_id) filter (where s.is_closed_won),
               9
        from days d
        left join scope s
               on s.snapshot_date = d.snapshot_date
              and s.program = '(multi)'
        group by d.snapshot_date
    )
    select snapshot_date, row_type, program, measurement,
           sourced_deals, sourced_pipeline, sourced_won, won_deals
    from (select * from program_rows
          union all
          select * from reconciling_rows) x
    order by snapshot_date, sort_order;
$function$

-- ---------------------------------------------------------------------
-- f_sourced_contacts_by_stage
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_sourced_contacts_by_stage(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, lifecycle_stage text, sourced_contacts bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg', 'public', 'pg_temp'
AS $function$
    select snapshot_date, lifecycle_stage, count(*)
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
    row_type,
    program,
    measurement,
    sourced_deals,
    sourced_pipeline,
    sourced_won,
    won_deals
   FROM mktg.f_sourced_by_program(true, NULL::integer) f_sourced_by_program(snapshot_date, row_type, program, measurement, sourced_deals, sourced_pipeline, sourced_won, won_deals);
