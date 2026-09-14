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
-- Captured after the 2026-09-14 migrations
-- (2026-09-14_f_close_rate.sql and
--  2026-09-14_influenced_pipeline_by_program.sql), both applied and
-- verified live the same day. New since the prior capture (2026-09-02):
-- f_influence_by_campaign / v_influence_by_campaign (staged 2026-09-02,
-- applied since, missed by the prior regeneration), f_close_rate /
-- v_close_rate, v_deal_program, f_influenced_pipeline,
-- f_influenced_by_program, f_influenced_by_combination, and
-- v_influenced_deal_detail. v_influence_headline and
-- v_sourced_contacts_by_stage remain dropped; see docs/migrations/.
-- =====================================================================

-- ============================== FUNCTIONS ==============================

-- -----------------------------------------------------------------------
-- f_close_rate
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_close_rate(close_year integer DEFAULT NULL::integer)
 RETURNS TABLE(snapshot_date date, segment_type text, segment_value text, measurement text, closed_deals bigint, won_count bigint, lost_count bigint, won_amount numeric, lost_amount numeric, deal_win_rate numeric, dollar_win_rate numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    -- Closed deals only. is_closed is nullable on the table, and `where
    -- is_closed` drops nulls, which is what we want: unknown is not
    -- closed. is_closed_won and amount_home are coalesced rather than
    -- trusted, so a future null cannot vanish from both won and lost
    -- while still counting in closed_deals and quietly breaking
    -- won + lost = closed.
    with scope as (
        select snapshot_date,
               coalesce(is_closed_won, false) as is_won,
               coalesce(is_amazon, false)     as is_amazon,
               coalesce(vertical, 'Unknown')  as vertical,
               coalesce(amount_home, 0)       as amount_home
        from snap_sourced_deal
        where is_closed
          and (close_year is null
               or extract(year from close_date) = close_year)
    ),
    floor_n as (
        select coalesce(
                 (select value::integer
                    from config_settings
                   where key = 'close_rate_min_closed'),
                 20) as min_closed
    ),
    -- One row per deal per segment type. A deal is counted three times
    -- across the three types, once within each. See the triple-count
    -- note in the header.
    segmented as (
        select snapshot_date, 'all'::text as segment_type,
               'All Net New'::text as segment_value, 1 as sort_order,
               is_won, amount_home
        from scope
        union all
        select snapshot_date, 'amazon',
               case when is_amazon then 'Amazon' else 'non-Amazon' end, 2,
               is_won, amount_home
        from scope
        union all
        select snapshot_date, 'vertical', vertical, 3,
               is_won, amount_home
        from scope
    ),
    agg as (
        select snapshot_date, segment_type, segment_value, sort_order,
               count(*)                                                  as closed_deals,
               count(*) filter (where is_won)                            as won_count,
               count(*) filter (where not is_won)                        as lost_count,
               coalesce(sum(amount_home) filter (where is_won), 0)       as won_amount,
               coalesce(sum(amount_home) filter (where not is_won), 0)   as lost_amount
        from segmented
        group by snapshot_date, segment_type, segment_value, sort_order
    )
    select a.snapshot_date,
           a.segment_type,
           a.segment_value,
           case when a.closed_deals >= f.min_closed
                then 'measured' else 'below_threshold' end,
           a.closed_deals,
           a.won_count,
           a.lost_count,
           a.won_amount,
           a.lost_amount,
           case when a.closed_deals >= f.min_closed and a.closed_deals > 0
                then round(a.won_count::numeric / a.closed_deals, 4) end,
           case when a.closed_deals >= f.min_closed
                     and (a.won_amount + a.lost_amount) > 0
                then round(a.won_amount / (a.won_amount + a.lost_amount), 4) end
    from agg a
    cross join floor_n f
    order by a.snapshot_date, a.sort_order, a.segment_value;
$function$

-- -----------------------------------------------------------------------
-- f_influence_by_campaign
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_influence_by_campaign(include_amazon boolean DEFAULT true, campaign_type_filter text DEFAULT NULL::text)
 RETURNS TABLE(snapshot_date date, campaign_id text, campaign_name text, campaign_type text, influenced_contacts bigint, deals_touched bigint, influenced_value_even_split numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with clean as (
        select *
        from snap_influence
        where not is_internal
          and not is_storefront
          and (include_amazon or not is_amazon)
          and (campaign_type_filter is null or campaign_type = campaign_type_filter)
    ),
    per_deal_campaign as (
        select distinct snapshot_date, deal_id, campaign_id, campaign_name,
               campaign_type, even_split_value
        from clean
    ),
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
$function$

-- -----------------------------------------------------------------------
-- f_influence_headline
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_influence_headline(include_amazon boolean DEFAULT true, close_year integer DEFAULT NULL::integer)
 RETURNS TABLE(snapshot_date date, total_deals bigint, deals_clean bigint, influenced_pipeline numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with clean as (
        select distinct snapshot_date, deal_id, amount_home
        from mktg.snap_influence
        where not is_internal and not is_storefront
          and (include_amazon or not is_amazon)
          and (close_year is null or extract(year from close_date) = close_year)
    )
    select
        snapshot_date,
        count(distinct deal_id) as total_deals,
        count(distinct deal_id) as deals_clean,
        sum(amount_home)        as influenced_pipeline
    from clean
    group by snapshot_date;
$function$

-- -----------------------------------------------------------------------
-- f_influenced_by_combination
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_influenced_by_combination(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, combination text, program_count integer, deals bigint, pipeline numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with per_deal as (
        select p.snapshot_date,
               p.deal_id,
               string_agg(p.program, ' + ' order by p.program) as combination,
               count(*)::integer                               as program_count,
               max(coalesce(d.amount_home, 0))                 as amount_home
        from v_deal_program p
        join snap_sourced_deal d
          on d.snapshot_date = p.snapshot_date
         and d.deal_id       = p.deal_id
        where include_amazon or not coalesce(d.is_amazon, false)
        group by p.snapshot_date, p.deal_id
    )
    select snapshot_date, combination, program_count,
           count(*), coalesce(sum(amount_home), 0)
    from per_deal
    group by snapshot_date, combination, program_count
    order by snapshot_date, count(*) desc, combination;
$function$

-- -----------------------------------------------------------------------
-- f_influenced_by_program
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_influenced_by_program(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, program text, measurement text, deals bigint, pipeline numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with days as (
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
    scope as (
        select p.snapshot_date, p.deal_id, p.program,
               coalesce(d.amount_home, 0) as amount_home
        from v_deal_program p
        join snap_sourced_deal d
          on d.snapshot_date = p.snapshot_date
         and d.deal_id       = p.deal_id
        where include_amazon or not coalesce(d.is_amazon, false)
    )
    select dy.snapshot_date,
           pr.program,
           case when pr.program = any(u.names)
                then 'not_measured' else 'measured' end,
           count(s.deal_id),
           coalesce(sum(s.amount_home), 0)
    from days dy
    cross join programs pr
    cross join unmeasured u
    left join scope s
           on s.snapshot_date = dy.snapshot_date
          and s.program       = pr.program
    group by dy.snapshot_date, pr.program, pr.sort_order, u.names
    order by dy.snapshot_date, pr.sort_order;
$function$

-- -----------------------------------------------------------------------
-- f_influenced_pipeline
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mktg.f_influenced_pipeline(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, row_type text, deals bigint, pipeline numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    with per_deal as (
        select p.snapshot_date,
               p.deal_id,
               count(*)                          as program_count,
               max(coalesce(d.amount_home, 0))   as amount_home
        from v_deal_program p
        join snap_sourced_deal d
          on d.snapshot_date = p.snapshot_date
         and d.deal_id       = p.deal_id
        where include_amazon or not coalesce(d.is_amazon, false)
        group by p.snapshot_date, p.deal_id
    )
    select snapshot_date, 'total'::text, count(*), coalesce(sum(amount_home), 0)
    from per_deal group by snapshot_date
    union all
    select snapshot_date, 'single_program', count(*), coalesce(sum(amount_home), 0)
    from per_deal where program_count = 1 group by snapshot_date
    union all
    select snapshot_date, 'multi_program', count(*), coalesce(sum(amount_home), 0)
    from per_deal where program_count > 1 group by snapshot_date
    order by 1, 2;
$function$

-- -----------------------------------------------------------------------
-- f_pipeline_model
-- -----------------------------------------------------------------------
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

-- -----------------------------------------------------------------------
-- f_sourced_by_program
-- -----------------------------------------------------------------------
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

-- -----------------------------------------------------------------------
-- f_sourced_contacts_by_stage
-- -----------------------------------------------------------------------
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

-- -----------------------------------------------------------------------
-- v_ad_performance
-- -----------------------------------------------------------------------
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
  GROUP BY snapshot_date, is_paid, source, account;;

-- -----------------------------------------------------------------------
-- v_close_rate
-- -----------------------------------------------------------------------
create or replace view mktg.v_close_rate as
SELECT snapshot_date,
    segment_type,
    segment_value,
    measurement,
    closed_deals,
    won_count,
    lost_count,
    won_amount,
    lost_amount,
    deal_win_rate,
    dollar_win_rate
   FROM mktg.f_close_rate(NULL::integer) f_close_rate(snapshot_date, segment_type, segment_value, measurement, closed_deals, won_count, lost_count, won_amount, lost_amount, deal_win_rate, dollar_win_rate);;

-- -----------------------------------------------------------------------
-- v_deal_program
-- -----------------------------------------------------------------------
create or replace view mktg.v_deal_program as
WITH cleaned AS (
         SELECT i.snapshot_date,
            i.deal_id,
            btrim(replace(replace(lower(i.campaign_name), 'campaign influence:'::text, ''::text), 'campaign influence :'::text, ''::text)) AS cname
           FROM mktg.snap_influence i
             JOIN mktg.snap_sourced_deal d ON d.snapshot_date = i.snapshot_date AND d.deal_id = i.deal_id
        )
 SELECT DISTINCT snapshot_date,
    deal_id,
    COALESCE(( SELECT k.program
           FROM mktg.config_program_keywords k
          WHERE POSITION((k.keyword) IN (c.cname)) > 0
          ORDER BY k.eval_order, k.id
         LIMIT 1), 'Content & Technology'::text) AS program
   FROM cleaned c;;

-- -----------------------------------------------------------------------
-- v_influence_by_campaign
-- -----------------------------------------------------------------------
create or replace view mktg.v_influence_by_campaign as
SELECT snapshot_date,
    campaign_id,
    campaign_name,
    campaign_type,
    influenced_contacts,
    deals_touched,
    influenced_value_even_split
   FROM mktg.f_influence_by_campaign(true, NULL::text) f_influence_by_campaign(snapshot_date, campaign_id, campaign_name, campaign_type, influenced_contacts, deals_touched, influenced_value_even_split);;

-- -----------------------------------------------------------------------
-- v_influenced_deal_detail
-- -----------------------------------------------------------------------
create or replace view mktg.v_influenced_deal_detail as
WITH combos AS (
         SELECT v_deal_program.snapshot_date,
            v_deal_program.deal_id,
            string_agg(v_deal_program.program, ' + '::text ORDER BY v_deal_program.program) AS combination,
            count(*)::integer AS program_count
           FROM mktg.v_deal_program
          GROUP BY v_deal_program.snapshot_date, v_deal_program.deal_id
        )
 SELECT i.snapshot_date,
    i.deal_id,
    d.deal_name,
    d.company_name,
    d.owner_name,
    d.amount_home,
    d.stage,
    d.close_date,
    d.is_closed,
    d.is_closed_won,
    d.is_amazon,
    d.vertical,
    c.combination,
    c.program_count,
    COALESCE(( SELECT k.program
           FROM mktg.config_program_keywords k
          WHERE POSITION((k.keyword) IN (btrim(replace(replace(lower(i.campaign_name), 'campaign influence:'::text, ''::text), 'campaign influence :'::text, ''::text)))) > 0
          ORDER BY k.eval_order, k.id
         LIMIT 1), 'Content & Technology'::text) AS program,
    i.contact_id,
    i.contact_name,
    i.contact_email,
    i.campaign_id,
    i.campaign_name
   FROM mktg.snap_influence i
     JOIN mktg.snap_sourced_deal d ON d.snapshot_date = i.snapshot_date AND d.deal_id = i.deal_id
     JOIN combos c ON c.snapshot_date = i.snapshot_date AND c.deal_id = i.deal_id;;

-- -----------------------------------------------------------------------
-- v_latest_snapshot
-- -----------------------------------------------------------------------
create or replace view mktg.v_latest_snapshot as
SELECT max(snapshot_date) AS snapshot_date
   FROM mktg.run_log
  WHERE status = 'ok'::text;;

-- -----------------------------------------------------------------------
-- v_sla_by_owner
-- -----------------------------------------------------------------------
create or replace view mktg.v_sla_by_owner as
SELECT snapshot_date,
    owner_name,
    count(*) AS contacts_worked,
    count(*) FILTER (WHERE over_sla) AS over_sla,
    round(avg(days_in_lifecycle_stage), 1) AS avg_days_in_stage
   FROM mktg.snap_lead_sla
  GROUP BY snapshot_date, owner_name;;

-- -----------------------------------------------------------------------
-- v_sla_by_status
-- -----------------------------------------------------------------------
create or replace view mktg.v_sla_by_status as
SELECT snapshot_date,
    lead_status,
    count(*) AS total_contacts,
    count(*) FILTER (WHERE over_sla) AS over_sla,
    round(100.0 * count(*) FILTER (WHERE over_sla)::numeric / NULLIF(count(*), 0)::numeric, 1) AS pct_over_sla,
    round(avg(days_in_status), 1) AS avg_days_in_status,
    round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (days_in_status::double precision))::numeric, 1) AS median_days_in_status
   FROM mktg.snap_lead_sla
  GROUP BY snapshot_date, lead_status;;

-- -----------------------------------------------------------------------
-- v_sourced_by_program
-- -----------------------------------------------------------------------
create or replace view mktg.v_sourced_by_program as
SELECT snapshot_date,
    row_type,
    program,
    measurement,
    sourced_deals,
    sourced_pipeline,
    sourced_won,
    won_deals
   FROM mktg.f_sourced_by_program(true, NULL::integer) f_sourced_by_program(snapshot_date, row_type, program, measurement, sourced_deals, sourced_pipeline, sourced_won, won_deals);;
