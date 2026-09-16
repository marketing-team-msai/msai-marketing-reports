-- =====================================================================
-- UP: influence-side program classification moves from name-keyword
--     guessing to HubSpot's real campaign_type property; single-program
--     exclusivity retired as the influence headline's gate
-- =====================================================================
-- Down version: 2026-09-15_influence_program_from_campaign_type.down.sql
--
-- SCOPE - READ THIS FIRST
--   This migration touches the INFLUENCE side only:
--     mktg.v_deal_program, mktg.v_influenced_deal_detail,
--     mktg.f_influenced_by_program, and a new mktg.v_deal_touch_summary.
--   It does NOT touch mktg.f_sourced_by_program, mktg.snap_sourced_deal,
--   is_single_program, or generate_netnew_report.PROGRAM_KEYWORDS. The
--   Net New / "sourced" side is a genuinely different question (does this
--   CONTACT's Lead Source indicate marketing origin) pending its own
--   future rework - not touched here, and not something campaign
--   influence data can answer on its own.
--
-- WHY - THE RATIFIED RULE THAT GOT RETIRED
--   CLAUDE.md's ratified rule 1 said sourced-pipeline metrics exclude any
--   deal touched by more than one program - "is_single_program is false
--   for uninfluenced and multi-program deals... governs the headline
--   number." That rule was calibrated for a world of 4-5 broad program
--   buckets, where most deals' campaigns happened to collapse into one
--   bucket. It was NEVER actually the rule for f_influenced_by_program /
--   f_influenced_pipeline - those already counted a touch as influence
--   regardless of exclusivity - but v_deal_program's classification still
--   came from guessing keywords in campaign_name, the same mechanism the
--   sourced side used.
--
--   Verified live 2026-09-15, moving from the original 4 slide-15 buckets
--   through a fifth (Webinars) to a full ~20-bucket real-campaign_type
--   taxonomy: the population of deals whose campaigns all happened to
--   collapse into ONE bucket kept shrinking as buckets got more precise
--   (71 -> 60 -> 51 -> 50, ex-Amazon), and at full granularity most
--   buckets (PR, Case Study, Whitepaper, Research Paper, Video,
--   Collateral, Web Content, Paid Search/Ads, Outsourced SDR, Survey,
--   Email) showed a permanent $0 in any exclusivity-gated headline -
--   not because there was no activity, but because those campaign types
--   essentially never occur as a deal's ONLY touch. Precision and
--   exclusivity pull in opposite directions; you can't have a headline
--   that is both is_single_program-gated and evidentiary about which
--   specific campaign type touched a deal.
--
--   Decided 2026-09-15: for the influence side, drop the exclusivity gate
--   entirely. Touch breadth (how many programs/campaigns touched a deal)
--   is a signal to REPORT, not a reason to exclude - verified live, the
--   37 deals touched by 3+ programs carried more pipeline ($6.49M) than
--   the 50 single-program deals ($1.6M) and the 21 two-program deals
--   ($1.2M) combined, so exclusivity was hiding the biggest deals.
--
-- WHAT CHANGES, MECHANICALLY
--   1. mktg.config_campaign_type_program (new table) - campaign_type ->
--      program, generated from generate_report.CAMPAIGN_TYPE_PROGRAM by
--      `sync_to_mktg.py --sync-campaign-types`, same pattern as
--      config_program_keywords / PROGRAM_KEYWORDS.
--   2. mktg.snap_influence.campaign_type (existing column, no schema
--      change) now holds the REAL HubSpot campaign_type where a list
--      links to a native Campaign (verified live: 91 of 100 lists,
--      2026-09-15), falling back to the old name-keyword guess only for
--      the handful that don't (8 paid-ad lists + 1 orphaned list, same
--      date). This is a Python-side change in generate_report.py /
--      sync_to_mktg.py, frozen per snapshot at ETL write time same as
--      every other column on that table - already-written snapshot rows
--      are NOT retroactively rewritten by this migration; only the next
--      daily run's new snapshot_date picks up real values going forward.
--   3. v_deal_program now joins snap_influence.campaign_type against
--      config_campaign_type_program instead of POSITION()-matching
--      keywords in campaign_name. Because campaign_type itself only
--      updates going forward (see #2), so does v_deal_program's
--      classification for any given snapshot_date - this migration
--      changes the MECHANISM, but a snapshot written before the next
--      daily run still carries the old guessed campaign_type value
--      underneath, and will classify accordingly until superseded.
--   4. v_influenced_deal_detail's per-row `program` column (previously
--      its own separate inline keyword lookup, duplicating v_deal_program's
--      logic) now reads the same config_campaign_type_program join.
--   5. f_influenced_by_program's `programs` dimension moves from the old
--      5 (Content & Technology / Events / Advertising / PR & Brand /
--      Webinars) to the new 10 broader buckets: Content, Webinars,
--      Events, Web Forms, Product Launch, PR & Media, Email,
--      Organic Social, Advertising, Outsourced SDR.
--   6. mktg.v_deal_touch_summary (new view) - one row per
--      (snapshot_date, deal_id): campaign_count (distinct campaigns),
--      program_count (distinct programs), programs (array of which).
--      Directly answers "how many campaigns, and which, are influencing
--      this deal" without excluding anything.
--
-- WHAT DOES NOT CHANGE
--   f_influenced_pipeline and f_influenced_by_combination already read
--   v_deal_program.program generically (no hardcoded program list), so
--   they pick up the new buckets automatically with no function change -
--   f_influenced_pipeline's overall `total` row_type was ALREADY every
--   influenced deal counted once regardless of touch count; only the
--   per-program breakdown objects needed the bucket-source change above.
--
-- ORDER OF OPERATIONS
--   1. Run PASTE 1 below in the Supabase SQL editor.
--   2. Run `python sync_to_mktg.py --sync-campaign-types` to populate
--      config_campaign_type_program (empty table + any v_deal_program
--      query joining against it would otherwise show every deal falling
--      to the 'Content' default in step 1's COALESCE, not a per-type
--      breakdown).
--   Same reasoning as the Webinars migration: reversed order makes
--   everything look like undifferentiated Content until both steps land.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres, so if any statement fails the whole paste
-- rolls back on its own.
-- =====================================================================


-- ============================== PASTE 1 ==============================

create table if not exists mktg.config_campaign_type_program (
    id            bigint generated by default as identity primary key,
    campaign_type text not null unique,
    program       text not null
);

grant select on mktg.config_campaign_type_program to authenticated;

comment on table mktg.config_campaign_type_program is
  'campaign_type -> program for INFLUENCE reporting only. Generated mirror '
  'of generate_report.CAMPAIGN_TYPE_PROGRAM - edit the Python dict, then '
  'run sync_to_mktg.py --sync-campaign-types. Unrelated to '
  'config_program_keywords, which still governs the separate, unchanged '
  'Net New / sourced-pipeline side.';

create or replace view mktg.v_deal_program as
select distinct
    i.snapshot_date,
    i.deal_id,
    coalesce(p.program, 'Content') as program
from mktg.snap_influence i
join mktg.snap_sourced_deal d
  on d.snapshot_date = i.snapshot_date and d.deal_id = i.deal_id
left join mktg.config_campaign_type_program p
       on p.campaign_type = i.campaign_type;

comment on view mktg.v_deal_program is
  'Dedupe grain for influence reporting: distinct (snapshot_date, deal_id, '
  'program). Program comes from snap_influence.campaign_type (the real '
  'HubSpot Campaign campaign_type where available, see CLAUDE.md "Real '
  'campaign_type") joined through config_campaign_type_program, not from '
  'guessing keywords in campaign_name. No exclusivity rule here - a deal '
  'legitimately appears once per distinct program it was touched by.';

create or replace view mktg.v_influenced_deal_detail as
with combos as (
    select v_deal_program.snapshot_date,
           v_deal_program.deal_id,
           string_agg(v_deal_program.program, ' + ' order by v_deal_program.program) as combination,
           count(*)::integer as program_count
    from mktg.v_deal_program
    group by v_deal_program.snapshot_date, v_deal_program.deal_id
)
select
    i.snapshot_date,
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
    coalesce(p.program, 'Content') as program,
    i.contact_id,
    i.contact_name,
    i.contact_email,
    i.campaign_id,
    i.campaign_name
from mktg.snap_influence i
join mktg.snap_sourced_deal d
  on d.snapshot_date = i.snapshot_date and d.deal_id = i.deal_id
join combos c
  on c.snapshot_date = i.snapshot_date and c.deal_id = i.deal_id
left join mktg.config_campaign_type_program p
       on p.campaign_type = i.campaign_type;

create or replace view mktg.v_deal_touch_summary as
select
    i.snapshot_date,
    i.deal_id,
    count(distinct i.campaign_name) as campaign_count,
    count(distinct coalesce(p.program, 'Content')) as program_count,
    array_agg(distinct coalesce(p.program, 'Content')
              order by coalesce(p.program, 'Content')) as programs
from mktg.snap_influence i
join mktg.snap_sourced_deal d
  on d.snapshot_date = i.snapshot_date and d.deal_id = i.deal_id
left join mktg.config_campaign_type_program p
       on p.campaign_type = i.campaign_type
group by i.snapshot_date, i.deal_id;

grant select on mktg.v_deal_touch_summary to authenticated;

comment on view mktg.v_deal_touch_summary is
  'One row per (snapshot_date, deal_id): campaign_count (distinct '
  'Campaign Influence lists that touched it), program_count (distinct '
  'broader programs), and programs (which ones). No exclusion of '
  'multi-touch deals - touch breadth is a metric to report, not a filter. '
  'Verified live 2026-09-15: deals touched by 3+ programs carried more '
  'pipeline than single- and two-program deals combined.';

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
        values ('Content',         1),
               ('Webinars',        2),
               ('Product Launch',  3),
               ('Events',          4),
               ('Web Forms',       5),
               ('PR & Media',      6),
               ('Email',           7),
               ('Organic Social',  8),
               ('Advertising',     9),
               ('Outsourced SDR', 10)
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


-- ============================== PASTE 2 ==============================
-- Verification. Run each individually (the editor only shows the last
-- statement's result if you run them together). Run AFTER
-- `python sync_to_mktg.py --sync-campaign-types`.

-- 2.1  config_campaign_type_program populated - expect 29 rows (24 real
--      HubSpot campaign_type values + 4 fallback-only: Blog, Event, Form,
--      Content that classify_campaign() can still produce for orphaned
--      lists), 10 distinct programs.
select count(*) as rows, count(distinct program) as distinct_programs
from mktg.config_campaign_type_program;

-- 2.2  f_influenced_by_program now returns 10 rows per snapshot_date, not
--      5. Content/Webinars/Product Launch/Events should show real
--      figures; Advertising/Outsourced SDR may show a genuine 0 if no
--      current deal happens to be touched by one (that was true
--      2026-09-15).
select program, measurement, deals, pipeline
from mktg.f_influenced_by_program(true)
where snapshot_date = (select max(snapshot_date) from mktg.snap_sourced_deal)
order by pipeline desc;

-- 2.3  Touch breadth - the actual point of this migration. Expect
--      3+-program deals to carry more pipeline than 1- and 2-program
--      deals combined (true 2026-09-15: $6.49M vs $1.6M + $1.2M).
select
    case when program_count = 1 then '1 program'
         when program_count = 2 then '2 programs'
         else '3+ programs' end as touch_breadth,
    count(*) as deals,
    sum(d.amount_home) as pipeline
from mktg.v_deal_touch_summary t
join mktg.snap_sourced_deal d
  on d.snapshot_date = t.snapshot_date and d.deal_id = t.deal_id
where t.snapshot_date = (select max(snapshot_date) from mktg.snap_sourced_deal)
  and not d.is_amazon
group by 1
order by 1;

-- 2.4  Sanity check that the overall influenced total (unaffected by any
--      of this - it was already exclusivity-free) did not move.
select row_type, deals, pipeline
from mktg.f_influenced_pipeline(true)
where snapshot_date = (select max(snapshot_date) from mktg.snap_sourced_deal)
  and row_type = 'total';
