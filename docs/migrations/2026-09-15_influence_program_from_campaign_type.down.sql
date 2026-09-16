-- =====================================================================
-- DOWN: revert influence-side program classification to name-keyword
--       guessing over campaign_name, drop the touch-summary view
-- =====================================================================
-- Reverts 2026-09-15_influence_program_from_campaign_type.sql.
--
-- Run this BEFORE reverting generate_report.py's CAMPAIGN_TYPE_PROGRAM /
-- campaign_type_by_name changes, same discipline as every other migration
-- pair here: revert the SQL mechanism first, then the Python source of
-- truth, so nothing reads a half-migrated state.
--
-- snap_influence.campaign_type rows already written with a REAL HubSpot
-- value (not the old keyword guess) are NOT rewritten by this - they keep
-- whatever value was frozen in at ETL time. v_deal_program reverting to
-- keyword-matching on campaign_name will classify those rows exactly as
-- it did before this migration existed, since it never depended on the
-- campaign_type column in the first place.
-- =====================================================================

drop view if exists mktg.v_deal_touch_summary;

create or replace view mktg.v_deal_program as
WITH cleaned AS (
    SELECT i.snapshot_date,
           i.deal_id,
           btrim(replace(replace(lower(i.campaign_name), 'campaign influence:', ''), 'campaign influence :', '')) AS cname
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
   FROM cleaned c;

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
     JOIN combos c ON c.snapshot_date = i.snapshot_date AND c.deal_id = i.deal_id;

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
               ('PR & Brand',           4),
               ('Webinars',             5)
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
$function$;

-- config_campaign_type_program is left in place (harmless once nothing
-- reads it) rather than dropped - drop it by hand only if you're certain
-- nothing else has come to depend on it.
