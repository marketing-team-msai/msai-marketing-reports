-- =====================================================================
-- UP: influenced pipeline counted once, participation by program, and
--     mutually exclusive program combinations
-- =====================================================================
-- Down version: 2026-09-14_influenced_pipeline_by_program.down.sql
--
-- Settles open item (e). 43 multi-program deals worth $2,931,048.04 were
-- credited to no program and appeared in no program-level total, visible
-- only as f_sourced_by_program's row_type = 'reconciling'.
--
-- WHAT THE DATA SAID, verified live 2026-09-14 before any of this was
-- designed:
--
--   Every multi-program deal touches EXACTLY TWO programs. No three-way.
--     Content & Technology + Events        41 deals  $2,907,483.04
--     Content & Technology + PR & Brand     2 deals     $23,565.00
--
--   Across all 114 influenced Net New deals, program presence is
--     Content & Technology  97%   Events 39%   PR & Brand 2%   Advertising 0%
--
--   So the single-program rule was not mis-attributing evenly. It was
--   hiding Events specifically: Events touches 44 deals worth
--   $3,109,583.04, of which only 3 worth $202,100.00 appeared anywhere,
--   because Events almost never occurs without Content and Content is on
--   nearly everything. 94% of Events-touched pipeline was invisible.
--
-- WHAT THIS MIGRATION DOES, AND DOES NOT DO
--   It does NOT change how a deal is classified, does NOT re-attribute
--   dollars, and does NOT invent a sourcing model. is_single_program and
--   f_sourced_by_program keep their exact current arithmetic. Events is
--   NOT promoted to source just because Content is common.
--
--   It adds three ways to count the same deals, each honest about what it
--   is, plus a drill-through:
--
--     f_influenced_pipeline        each deal ONCE. 114 / $9,533,793.08,
--                                  split into single-program 71 and
--                                  multi-program 43 as supporting rows.
--     f_influenced_by_program      each program gets the FULL value of
--                                  every deal it touched. NOT ADDITIVE.
--     f_influenced_by_combination  mutually exclusive. Each deal in
--                                  exactly one row. Reconciles to the
--                                  headline exactly.
--     v_influenced_deal_detail     deal x contact x campaign behind all
--                                  of the above.
--
-- THE DEDUPE IS THE WHOLE POINT, SAME AS f_influence_by_campaign
--   snap_influence is deal x contact x campaign. A deal with four
--   contacts on three campaigns is twelve rows carrying the full deal
--   amount each. Measured on this snapshot:
--
--     naive sum over snap_influence rows      $39,354,872.17
--     deduped at deal x program               $12,464,841.12
--     unique deals, the headline               $9,533,793.08
--
--   61 of the 157 (deal, program) pairs are backed by more than one row.
--   v_deal_program collapses to distinct (snapshot_date, deal_id,
--   program) and EVERYTHING here is built on it. Do not add a column to
--   v_deal_program that is summed, and do not build a dollar figure by
--   summing snap_influence rows.
--
--   This is the property to re-test after any change: adding another
--   contact or another campaign inside a program a deal already has must
--   not move that program's dollars. Query 2.7 asserts it.
--
-- PROGRAM CLASSIFICATION IN SQL
--   classify_program() is Python. config_program_keywords is its mirror:
--   same keywords, same evaluation order, Content & Technology as the
--   fallback. Verified identical on 2026-09-14 - 11/18/6 keywords each
--   matching the module's ADV_KW / EVENT_KW / PR_KW exactly, and zero
--   disagreements across all 29 distinct campaign names in the snapshot.
--   THAT IS TWO SOURCES OF TRUTH and they will drift eventually. Query
--   2.8 re-checks the classification against the stored
--   is_single_program flag every time you run it.
--
--   campaign_type is NOT the program. It is HubSpot's own taxonomy
--   (Content, Event, Webinar, Form, Whitepaper, Video, Case Study, PR)
--   and it cuts a different way. Nothing here reads it.
--
-- SCOPE, WHICH DIFFERS FROM f_influence_by_campaign - READ THIS
--   These objects are NET NEW ONLY. They inner-join snap_sourced_deal, so
--   the population is deals in the Net New Pipeline created on or after
--   config_settings.window_anchor_netnew. snap_influence itself is
--   PORTAL-WIDE: it holds 136 distinct deals in this snapshot, 22 of
--   which are not Net New and are dropped here.
--
--   So f_influenced_by_program totals will NOT match
--   f_influence_by_campaign totals, and that is correct, not a bug. They
--   answer different questions over different populations. Never compare
--   them without matching the filters first.
--
--   include_amazon behaves as everywhere else. Ex-Amazon the headline is
--   107 deals / $9,169,843.49.
--
-- EVEN SPLIT IS UNTOUCHED AND STAYS WHERE IT IS
--   snap_influence.even_split_value and f_influence_by_campaign keep
--   their current behaviour. They are now labelled "Allocated influenced
--   pipeline - even split" via config_settings, because "influenced
--   pipeline" alone no longer distinguishes them from the participation
--   view added here. Equal splitting is deliberately NOT used for
--   participation: a program that touched a deal shows the whole deal, or
--   the row would be an allocation wearing a participation label.
--
-- TERMINOLOGY
--   The single-program rule identifies single-program INFLUENCE, not
--   opportunity origin. Its display label is now "Single-program
--   influenced pipeline", carried in config_settings so the dashboard
--   reads it live. Column names in f_sourced_by_program are deliberately
--   NOT renamed: the Lovable dashboard reads sourced_deals and
--   sourced_pipeline by name and this repo cannot update it. The label
--   change has to be applied in msa-dash-pro too.
--
-- Paste PASTE 1 into the Supabase SQL editor and Run. Then paste PASTE 2
-- and Run, and compare against the expected output beside each query. Do
-- not edit this file to match what you get.
--
-- No explicit BEGIN. A multi-statement paste is already one implicit
-- transaction in Postgres.
-- =====================================================================


-- ============================== PASTE 1 ==============================

-- Display labels. In config_settings so the dashboard reads them live
-- rather than hard-coding, the same reason window_anchor_netnew lives
-- there. None of these restates a number or a date held elsewhere.
insert into mktg.config_settings (key, value, value_type, description)
values
  ('label_single_program', 'Single-program influenced pipeline', 'text',
   'Display label for the is_single_program metric. The rule identifies '
   'single-program influence, not opportunity origin, so it is no longer '
   'labelled "sourced". Calculation unchanged; supporting metric.'),
  ('label_influenced_by_program',
   'Programs may influence the same deal. Rows are not additive.', 'text',
   'Required caption for f_influenced_by_program. Any overall total must '
   'count unique deals, never sum the program rows.'),
  ('label_allocated_even_split',
   'Allocated influenced pipeline - even split', 'text',
   'Display label for even_split_value and f_influence_by_campaign. The '
   'deal amount is divided equally across the full union of campaigns '
   'that touched the deal, so rows are additive but no single row is the '
   'whole deal. Distinct from program participation, which is not split.'),
  ('label_influenced_scope',
   'Net New Pipeline, deals created on or after the window anchor. '
   'Campaign Influence list membership is the engagement test.', 'text',
   'Scope caption for the influenced-pipeline views. Compose with '
   'window_anchor_netnew for the date; do not hard-code it. snap_influence '
   'itself is portal-wide - these views are not.')
on conflict (key) do update
  set value = excluded.value,
      value_type = excluded.value_type,
      description = excluded.description,
      updated_at = now();


-- ---------------------------------------------------------------------
-- v_deal_program - THE building block. Distinct (snapshot, deal,
-- program). Every object below reads this and nothing below re-reads
-- snap_influence for dollars.
--
-- Engagement eligibility, unchanged from the existing rule: a deal
-- qualifies for a program when at least one contact associated with the
-- deal is a member of at least one Campaign Influence list whose name
-- classifies to that program. There is no minimum touch count, no
-- recency window, and no contact-role test. is_internal is not filtered
-- because it does no work on snap_influence - zero rows across 128 email
-- domains - unlike on snap_sourced_contact where it fires correctly.
-- ---------------------------------------------------------------------
create or replace view mktg.v_deal_program as
with cleaned as (
    -- Mirrors classify_program's normalisation exactly: lower, strip the
    -- "Campaign Influence:" prefix in both spellings, trim.
    select i.snapshot_date,
           i.deal_id,
           btrim(replace(replace(lower(i.campaign_name),
                                 'campaign influence:', ''),
                         'campaign influence :', '')) as cname
    from mktg.snap_influence i
    join mktg.snap_sourced_deal d
      on d.snapshot_date = i.snapshot_date
     and d.deal_id       = i.deal_id
)
select distinct
       c.snapshot_date,
       c.deal_id,
       coalesce(
         (select k.program
            from mktg.config_program_keywords k
           where position(k.keyword in c.cname) > 0
           order by k.eval_order, k.id
           limit 1),
         'Content & Technology') as program
from cleaned c;


-- ---------------------------------------------------------------------
-- f_influenced_pipeline - each deal counted ONCE, with the single vs
-- multi split as supporting rows. row_type 'total' is the headline;
-- 'single_program' + 'multi_program' sum back to it exactly.
-- ---------------------------------------------------------------------
drop function if exists mktg.f_influenced_pipeline(boolean);

create or replace function mktg.f_influenced_pipeline(
    include_amazon boolean default true)
returns table (
    snapshot_date date,
    row_type      text,
    deals         bigint,
    pipeline      numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
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
$function$;


-- ---------------------------------------------------------------------
-- f_influenced_by_program - participation. Each program gets the FULL
-- value of every deal it touched.
--
-- ROWS ARE NOT ADDITIVE. A deal touched by two programs is in both rows
-- at full value. On 2026-09-14 the rows sum to $12,464,841.12 against a
-- true total of $9,533,793.08. Render
-- config_settings.label_influenced_by_program beside it and take any
-- overall total from f_influenced_pipeline's 'total' row.
--
-- All four programs always return a row, so the shape is stable.
-- Advertising's zero is 'not_measured' - no ad source is captured, same
-- reason and same word as f_sourced_by_program. PR & Brand's is real.
-- ---------------------------------------------------------------------
drop function if exists mktg.f_influenced_by_program(boolean);

create or replace function mktg.f_influenced_by_program(
    include_amazon boolean default true)
returns table (
    snapshot_date date,
    program       text,
    measurement   text,
    deals         bigint,
    pipeline      numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
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
$function$;


-- ---------------------------------------------------------------------
-- f_influenced_by_combination - mutually exclusive. Every influenced deal
-- belongs to exactly one combination, so these rows DO sum, and they sum
-- to f_influenced_pipeline's 'total' row exactly.
--
-- Unlike f_influenced_by_program this returns only combinations that
-- exist, so the row count moves as the data moves.
-- ---------------------------------------------------------------------
drop function if exists mktg.f_influenced_by_combination(boolean);

create or replace function mktg.f_influenced_by_combination(
    include_amazon boolean default true)
returns table (
    snapshot_date date,
    combination   text,
    program_count integer,
    deals         bigint,
    pipeline      numeric
)
language sql
stable
set search_path to 'mktg'
as $function$
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
$function$;


-- ---------------------------------------------------------------------
-- v_influenced_deal_detail - drill-through behind every row above.
-- Grain is deal x contact x campaign, 248 rows for the Net New
-- population on 2026-09-14.
--
-- amount_home REPEATS on every row. Never sum it here. This view is for
-- listing who and what touched a deal, nothing else. Dollars come from
-- the three functions above.
--
-- It is a plain view, so PostgREST caps it at 1000 rows and it carries
-- every snapshot. Filter on snapshot_date AND page it, the way
-- fetchInfluenceDeals already pages snap_influence.
-- ---------------------------------------------------------------------
create or replace view mktg.v_influenced_deal_detail as
with combos as (
    select snapshot_date, deal_id,
           string_agg(program, ' + ' order by program) as combination,
           count(*)::integer                           as program_count
    from mktg.v_deal_program
    group by snapshot_date, deal_id
)
select i.snapshot_date,
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
       coalesce(
         (select k.program
            from mktg.config_program_keywords k
           where position(k.keyword in
                   btrim(replace(replace(lower(i.campaign_name),
                                         'campaign influence:', ''),
                                 'campaign influence :', ''))) > 0
           order by k.eval_order, k.id
           limit 1),
         'Content & Technology') as program,
       i.contact_id,
       i.contact_name,
       i.contact_email,
       i.campaign_id,
       i.campaign_name
from mktg.snap_influence i
join mktg.snap_sourced_deal d
  on d.snapshot_date = i.snapshot_date
 and d.deal_id       = i.deal_id
join combos c
  on c.snapshot_date = i.snapshot_date
 and c.deal_id       = i.deal_id;


grant select on mktg.v_deal_program            to authenticated;
grant select on mktg.v_influenced_deal_detail  to authenticated;
grant execute on function mktg.f_influenced_pipeline(boolean)       to authenticated;
grant execute on function mktg.f_influenced_by_program(boolean)     to authenticated;
grant execute on function mktg.f_influenced_by_combination(boolean) to authenticated;


comment on view mktg.v_deal_program is
  'Distinct (snapshot_date, deal_id, program) for Net New deals with '
  'Campaign Influence engagement. The dedupe grain everything else is '
  'built on. Program comes from config_program_keywords, mirroring '
  'classify_program(); campaign_type is a different taxonomy and is not '
  'used. Do not add a summable column here.';

comment on function mktg.f_influenced_by_program(boolean) is
  'Participation, not allocation: each program carries the FULL value of '
  'every deal it touched, so ROWS ARE NOT ADDITIVE and their sum is '
  'meaningless. Take totals from f_influenced_pipeline. Net New only, '
  'unlike portal-wide f_influence_by_campaign. Returns every '
  'snapshot_date: filter server-side.';

comment on function mktg.f_influenced_by_combination(boolean) is
  'Mutually exclusive program combinations. Every influenced deal is in '
  'exactly one row, so these rows DO sum and reconcile to '
  'f_influenced_pipeline row_type = total. Returns every snapshot_date: '
  'filter server-side.';


-- ============================== PASTE 2 ==============================
-- Verification. Expected values are live figures for snapshot
-- 2026-09-14 and move with CRM activity on later snapshots - re-derive
-- rather than assuming a mismatch is a bug.

-- 2.1  Headline, each deal once. THE reconciliation from the spec.
--
-- expected:
--   multi_program    43   2931048.04
--   single_program   71   6602745.04
--   total           114   9533793.08
select row_type, deals, pipeline
from mktg.f_influenced_pipeline(true)
where snapshot_date = '2026-09-14'
order by row_type;

-- 2.2  single + multi must equal total, on every snapshot, both toggles.
--
-- expected: 0 rows
select snapshot_date, include_amazon, total_deals, part_deals,
       total_pipeline, part_pipeline
from (
    select f.snapshot_date, t.include_amazon,
           max(f.deals)    filter (where f.row_type = 'total')          as total_deals,
           sum(f.deals)    filter (where f.row_type <> 'total')         as part_deals,
           max(f.pipeline) filter (where f.row_type = 'total')          as total_pipeline,
           sum(f.pipeline) filter (where f.row_type <> 'total')         as part_pipeline
    from (values (true), (false)) t(include_amazon)
    cross join lateral mktg.f_influenced_pipeline(t.include_amazon) f
    group by f.snapshot_date, t.include_amazon
) x
where total_deals <> part_deals or total_pipeline <> part_pipeline;

-- 2.3  Participation by program. NOT ADDITIVE - the sum below is shown
--      precisely so the gap is visible, never to be rendered.
--
-- expected:
--   Content & Technology  measured      111   9331693.08
--   Events                measured       44   3109583.04
--   Advertising           not_measured    0         0.00
--   PR & Brand            measured        2     23565.00
--   sum of rows                         157  12464841.12   <- meaningless
--   true total (2.1)                    114   9533793.08
select program, measurement, deals, pipeline
from mktg.f_influenced_by_program(true)
where snapshot_date = '2026-09-14';

-- 2.4  Mutually exclusive combinations, and they reconcile.
--
-- expected: 4 rows summing to 114 / 9533793.08
--   Content & Technology                 1   68   6400645.04
--   Content & Technology + Events        2   41   2907483.04
--   Events                               1    3    202100.00
--   Content & Technology + PR & Brand    2    2     23565.00
select combination, program_count, deals, pipeline
from mktg.f_influenced_by_combination(true)
where snapshot_date = '2026-09-14'
order by deals desc, combination;

-- 2.5  Combinations reconcile to the headline on EVERY snapshot and both
--      toggles. This is the guarantee the spec asks for.
--
-- expected: 0 rows
select * from (
    select c.snapshot_date, t.include_amazon,
           sum(c.deals)    as combo_deals,
           sum(c.pipeline) as combo_pipeline,
           max(h.deals)    as head_deals,
           max(h.pipeline) as head_pipeline
    from (values (true), (false)) t(include_amazon)
    cross join lateral mktg.f_influenced_by_combination(t.include_amazon) c
    join lateral mktg.f_influenced_pipeline(t.include_amazon) h
      on h.snapshot_date = c.snapshot_date and h.row_type = 'total'
    group by c.snapshot_date, t.include_amazon
) x
where combo_deals <> head_deals or combo_pipeline <> head_pipeline;

-- 2.6  Ex-Amazon. Multi-program is entirely non-Amazon, so only the
--      single-program and total rows move.
--
-- expected:
--   multi_program    43   2931048.04
--   single_program   64   6238795.45
--   total           107   9169843.49
select row_type, deals, pipeline
from mktg.f_influenced_pipeline(false)
where snapshot_date = '2026-09-14'
order by row_type;

-- 2.7  THE DEDUPE PROPERTY. Every (deal, program) pair must appear once
--      in v_deal_program no matter how many contacts or campaigns back
--      it. 61 of 157 pairs have more than one row behind them, so this
--      is not vacuous.
--
-- expected: pairs 157, rows_behind 248, duplicated_pairs 0
select (select count(*) from mktg.v_deal_program
         where snapshot_date = '2026-09-14')                      as pairs,
       (select count(*) from mktg.v_influenced_deal_detail
         where snapshot_date = '2026-09-14')                      as rows_behind,
       (select count(*) from (
            select snapshot_date, deal_id, program, count(*)
            from mktg.v_deal_program
            where snapshot_date = '2026-09-14'
            group by 1, 2, 3 having count(*) > 1) y)              as duplicated_pairs;

-- 2.8  The SQL classification agrees with the stored is_single_program.
--      config_program_keywords and classify_program() are two sources of
--      truth; this is the drift alarm. Run it after any keyword change.
--
-- expected: 0 rows
select d.deal_id, d.program as stored_program, d.is_single_program,
       count(p.program) as sql_program_count
from mktg.snap_sourced_deal d
join mktg.v_deal_program p
  on p.snapshot_date = d.snapshot_date and p.deal_id = d.deal_id
where d.snapshot_date = '2026-09-14'
group by d.deal_id, d.program, d.is_single_program
having (count(p.program) = 1) <> coalesce(d.is_single_program, false);

-- 2.9  Scope is Net New, not portal-wide. snap_influence carries deals
--      this correctly drops.
--
-- expected: influence_deals 136, netnew_influenced 114, dropped 22
select (select count(distinct deal_id) from mktg.snap_influence
         where snapshot_date = '2026-09-14')                      as influence_deals,
       (select count(distinct deal_id) from mktg.v_deal_program
         where snapshot_date = '2026-09-14')                      as netnew_influenced,
       (select count(distinct i.deal_id) from mktg.snap_influence i
         left join mktg.snap_sourced_deal d
                on d.snapshot_date = i.snapshot_date and d.deal_id = i.deal_id
         where i.snapshot_date = '2026-09-14' and d.deal_id is null) as dropped;

-- 2.10 A Content + Events deal appears exactly once in the headline,
--      once in each program's participation row, and once in the
--      Content + Events combination. Named example, spec's own test.
--
-- expected: 1, 1, 1, 1 - headline_rows, content_rows, events_rows,
-- combo_rows - for whichever deal the first line picks.
with pick as (
    select deal_id from mktg.v_deal_program
    where snapshot_date = '2026-09-14'
    group by deal_id
    having string_agg(program, ' + ' order by program)
           = 'Content & Technology + Events'
    order by deal_id limit 1
)
select (select count(*) from mktg.v_deal_program v, pick
         where v.snapshot_date = '2026-09-14' and v.deal_id = pick.deal_id
           and v.program = 'Content & Technology')                as content_rows,
       (select count(*) from mktg.v_deal_program v, pick
         where v.snapshot_date = '2026-09-14' and v.deal_id = pick.deal_id
           and v.program = 'Events')                              as events_rows,
       (select count(*) from mktg.v_deal_program v, pick
         where v.snapshot_date = '2026-09-14' and v.deal_id = pick.deal_id) as total_program_rows,
       (select count(distinct v.campaign_id)
          from mktg.v_influenced_deal_detail v, pick
         where v.snapshot_date = '2026-09-14' and v.deal_id = pick.deal_id) as campaigns_behind_it;

-- 2.11 Drill-through returns contacts and campaigns for one combination.
--      Inspect, do not sum amount_home.
select deal_name, company_name, program, contact_name, contact_email,
       campaign_name, amount_home
from mktg.v_influenced_deal_detail
where snapshot_date = '2026-09-14'
  and combination = 'Content & Technology + Events'
order by deal_name, program, contact_name, campaign_name
limit 25;
