-- =====================================================================
-- UP: replace the "Net New / Sourced" page's single-program /
--     multi-program framing with an actual marketing-sourced-new-
--     business measure (deal type + contact lead_source + campaign
--     influence, both signals required)
-- =====================================================================
-- Down version: 2026-09-16_marketing_sourced.down.sql
--
-- SCOPE - READ THIS FIRST
--   This migration is entirely NEW ADDITIVE state. It does not touch
--   mktg.f_sourced_by_program, is_single_program, config_program_keywords,
--   or PROGRAM_KEYWORDS - that objects/rule stays exactly as it was and
--   keeps answering its own question (campaign touch breadth: did every
--   campaign that touched this deal map to one program). It was never
--   actually a "was this deal marketing-sourced" measure, and Alecia
--   confirmed on 2026-09-16 that the page reading it had been read that
--   way by mistake.
--
-- WHY
--   Alecia's actual question: for a NEW BUSINESS deal, does the
--   associated contact's HubSpot lead_source (a custom picklist -
--   Trade Show, Cold Call, Paid Search, Outsourced SDR, etc, NOT the
--   standard hs_analytics_source "Original Traffic Source") indicate
--   marketing origin, AND did a marketing campaign actually touch the
--   deal. Neither signal alone was being measured anywhere in this
--   schema - confirmed by grep, both are net-new additions:
--     - deal_type (HubSpot picklist: newbusiness / existingbusiness /
--       Renewal) was never pulled from HubSpot at all.
--     - contact lead_source was never pulled from HubSpot at all.
--   Both signals are REQUIRED to agree (Alecia's explicit call,
--   2026-09-16) - a deal with only one signal is real and reportable,
--   just not counted as Marketing Sourced. See sourcing_status below.
--
-- WHAT CHANGES, MECHANICALLY
--   1. mktg.snap_sourced_deal gains 7 columns (deal_type,
--      is_new_business, has_marketing_lead_source,
--      marketing_lead_sources, primary_lead_source, marketing_sourced,
--      sourcing_status), computed in Python at ETL write time in
--      generate_netnew_report.build_dataset() - same "frozen per
--      snapshot" treatment as program / is_single_program on the same
--      table, and the same reason: already-written snapshot_dates are
--      NOT backfilled by this migration. This is PROSPECTIVE ONLY,
--      same precedent as the 2026-09-15 Webinars program addition -
--      already-written rows keep sourcing_status = 'unknown_deal_type'
--      (deal_type was never pulled before this) until the next daily
--      run writes a new snapshot_date.
--   2. mktg.config_lead_source_bucket (new table) - lead_source ->
--      bucket ('marketing' / 'sales' / 'other'), generated mirror of
--      generate_netnew_report.LEAD_SOURCE_BUCKET, reconciled by
--      `sync_to_mktg.py --sync-lead-source-buckets`. Same pattern as
--      config_program_keywords / config_campaign_type_program. Not
--      read by any view here (the bucket decision is frozen into
--      snap_sourced_deal in Python, same as sourced-side program
--      always has been) - it exists so the mapping can be inspected
--      and audited in SQL without reading Python.
--   3. marketing_lead_sources (text[]) holds every distinct
--      marketing-bucketed lead_source value found across ALL of the
--      deal's associated contacts (any contact counts, not only
--      influenced ones) - reported for transparency, never summed.
--      primary_lead_source is the ONE such value from whichever
--      contact was created earliest, giving each deal exactly one
--      value so a by-lead-source dollar breakdown can sum without
--      double counting - the same exclusivity trick is_single_program
--      already relies on for the by-program breakdown, applied here to
--      lead source instead of to campaign touches.
--   4. sourcing_status (one of six values, computed once per deal):
--        marketing_sourced        - new business, lead source AND
--                                    campaign influence both marketing
--        partial_lead_source_only - new business, lead source says
--                                    marketing, no campaign touched it
--        partial_campaign_only    - new business, a campaign touched
--                                    it, lead source does not say
--                                    marketing
--        not_marketing_sourced    - new business, neither signal
--        repeat_business          - deal_type is existingbusiness or
--                                    Renewal (grouped together per
--                                    Alecia, 2026-09-16)
--        unknown_deal_type        - deal_type is blank or unrecognized
--      The partial_* statuses are deliberately kept visible rather than
--      folded into not_marketing_sourced - a deal where the two signals
--      disagree is exactly the case worth seeing, not noise to average
--      away.
--   5. Three new query objects, all filtering/grouping on the new
--      columns, mirroring f_sourced_by_program's shape (STABLE SQL
--      function + a same-body view, and EVERY row for EVERY
--      snapshot_date - filter server-side on snapshot_date, same
--      caution as every other f_*/v_* object here):
--        f_marketing_sourced(include_amazon, close_year)
--          -> mktg.v_marketing_sourced
--          one row per (snapshot_date, sourcing_status): deals,
--          pipeline, won, won_deals. The headline split.
--        f_marketing_sourced_by_lead_source(include_amazon)
--          -> mktg.v_marketing_sourced_by_lead_source
--          Marketing Sourced deals only, grouped by primary_lead_source.
--          Sums are safe: primary_lead_source is exclusive per deal.
--        f_marketing_sourced_by_program(include_amazon)
--          -> mktg.v_marketing_sourced_by_program
--          Marketing Sourced deals only, grouped by the deal's existing
--          `program` value (single program, or '(multi)' for deals
--          touched by more than one program - unchanged column, reused
--          here, still exclusive per deal so sums are safe).
--
-- WHAT DOES NOT CHANGE
--   f_sourced_by_program, is_single_program, config_program_keywords,
--   PROGRAM_KEYWORDS: untouched, and still the answer to "how many
--   programs touched this deal" (campaign touch breadth). The Lovable
--   dashboard's OLD "Net New / Sourced" page (single-program /
--   multi-program) needs to be pointed at the new objects above and
--   the old framing retired from that page - a separate, follow-up
--   change in msa-dash-pro, same open-item pattern as every prior label
--   change noted in CLAUDE.md.
--
-- ORDER OF OPERATIONS
--   1. Run PASTE 1 below in the Supabase SQL editor.
--   2. Run `python sync_to_mktg.py --sync-lead-source-buckets` to
--      populate config_lead_source_bucket (harmless if skipped - no
--      view reads it - but keeps the audit mirror from reading empty).
--   3. Run the next daily sync (or `sync_to_mktg.py --only netnew`) to
--      write a snapshot_date where sourcing_status is actually
--      populated. Every already-written snapshot_date will show 100%
--      unknown_deal_type until then - that is correct, not a bug.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres, so if any statement fails the whole paste
-- rolls back on its own.
-- =====================================================================


-- ============================== PASTE 1 ==============================

alter table mktg.snap_sourced_deal
  add column if not exists deal_type                 text,
  add column if not exists is_new_business            boolean,
  add column if not exists has_marketing_lead_source   boolean not null default false,
  add column if not exists marketing_lead_sources      text[]  not null default '{}',
  add column if not exists primary_lead_source         text,
  add column if not exists marketing_sourced           boolean not null default false,
  add column if not exists sourcing_status             text    not null default 'unknown_deal_type';

comment on column mktg.snap_sourced_deal.sourcing_status is
  'One of: marketing_sourced, partial_lead_source_only, '
  'partial_campaign_only, not_marketing_sourced, repeat_business, '
  'unknown_deal_type. Computed once in Python at ETL write time from '
  'HubSpot deal_type + contact lead_source + campaign influence - see '
  'generate_netnew_report.build_dataset() and CLAUDE.md.';

create table if not exists mktg.config_lead_source_bucket (
    id           bigint generated by default as identity primary key,
    lead_source  text not null unique,
    bucket       text not null
);

grant select on mktg.config_lead_source_bucket to authenticated;

comment on table mktg.config_lead_source_bucket is
  'contact lead_source -> bucket (marketing / sales / other) for the '
  'Marketing Sourced report. Generated mirror of '
  'generate_netnew_report.LEAD_SOURCE_BUCKET - edit the Python dict, then '
  'run sync_to_mktg.py --sync-lead-source-buckets. Not read by any view: '
  'the bucket decision is frozen into snap_sourced_deal in Python, same '
  'as program / is_single_program always have been. Exists for audit.';

insert into mktg.config_settings (key, value, value_type, description)
values
  ('label_marketing_sourced',
   'New business where the contact''s lead source and a marketing '
   'campaign both point to marketing origin', 'text',
   'Display label for sourcing_status = marketing_sourced. Both signals '
   'are required to agree, per Alecia 2026-09-16 - a deal with only one '
   'signal shows as partial_lead_source_only or partial_campaign_only, '
   'not as marketing_sourced.'),
  ('label_marketing_sourced_scope',
   'Net New Pipeline, deal_type = New Business only. Existing Business '
   'and Renewal are reported separately as repeat business.', 'text',
   'Scope caption for the marketing-sourced views. Renewal is grouped '
   'with Existing Business as repeat business per Alecia, 2026-09-16.')
on conflict (key) do update
  set value = excluded.value,
      value_type = excluded.value_type,
      description = excluded.description,
      updated_at = now();

CREATE OR REPLACE FUNCTION mktg.f_marketing_sourced(include_amazon boolean DEFAULT true, close_year integer DEFAULT NULL::integer)
 RETURNS TABLE(snapshot_date date, sourcing_status text, deals bigint, pipeline numeric, won numeric, won_deals bigint)
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
    statuses (sourcing_status, sort_order) as (
        values ('marketing_sourced',         1),
               ('partial_lead_source_only',  2),
               ('partial_campaign_only',     3),
               ('not_marketing_sourced',     4),
               ('repeat_business',           5),
               ('unknown_deal_type',         6)
    )
    select d.snapshot_date,
           st.sourcing_status,
           count(s.deal_id)                                              as deals,
           coalesce(sum(s.amount_home), 0)                               as pipeline,
           coalesce(sum(s.amount_home) filter (where s.is_closed_won), 0) as won,
           count(s.deal_id) filter (where s.is_closed_won)               as won_deals
    from days d
    cross join statuses st
    left join scope s
           on s.snapshot_date = d.snapshot_date
          and s.sourcing_status = st.sourcing_status
    group by d.snapshot_date, st.sourcing_status, st.sort_order
    order by d.snapshot_date, st.sort_order;
$function$;

create or replace view mktg.v_marketing_sourced as
select * from mktg.f_marketing_sourced(true, null);

CREATE OR REPLACE FUNCTION mktg.f_marketing_sourced_by_lead_source(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, lead_source text, deals bigint, pipeline numeric, won numeric, won_deals bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    select snapshot_date,
           primary_lead_source as lead_source,
           count(*)                                                      as deals,
           coalesce(sum(amount_home), 0)                                  as pipeline,
           coalesce(sum(amount_home) filter (where is_closed_won), 0)     as won,
           count(*) filter (where is_closed_won)                         as won_deals
    from snap_sourced_deal
    where sourcing_status = 'marketing_sourced'
      and (include_amazon or not is_amazon)
    group by snapshot_date, primary_lead_source
    order by snapshot_date, pipeline desc;
$function$;

create or replace view mktg.v_marketing_sourced_by_lead_source as
select * from mktg.f_marketing_sourced_by_lead_source(true);

CREATE OR REPLACE FUNCTION mktg.f_marketing_sourced_by_program(include_amazon boolean DEFAULT true)
 RETURNS TABLE(snapshot_date date, program text, deals bigint, pipeline numeric, won numeric, won_deals bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mktg'
AS $function$
    select snapshot_date,
           coalesce(program, '(uninfluenced)') as program,
           count(*)                                                      as deals,
           coalesce(sum(amount_home), 0)                                 as pipeline,
           coalesce(sum(amount_home) filter (where is_closed_won), 0)    as won,
           count(*) filter (where is_closed_won)                        as won_deals
    from snap_sourced_deal
    where sourcing_status = 'marketing_sourced'
      and (include_amazon or not is_amazon)
    group by snapshot_date, coalesce(program, '(uninfluenced)')
    order by snapshot_date, pipeline desc;
$function$;

create or replace view mktg.v_marketing_sourced_by_program as
select * from mktg.f_marketing_sourced_by_program(true);

grant select on mktg.v_marketing_sourced                to authenticated;
grant select on mktg.v_marketing_sourced_by_lead_source  to authenticated;
grant select on mktg.v_marketing_sourced_by_program      to authenticated;
grant execute on function mktg.f_marketing_sourced(boolean, integer)      to authenticated;
grant execute on function mktg.f_marketing_sourced_by_lead_source(boolean) to authenticated;
grant execute on function mktg.f_marketing_sourced_by_program(boolean)     to authenticated;
