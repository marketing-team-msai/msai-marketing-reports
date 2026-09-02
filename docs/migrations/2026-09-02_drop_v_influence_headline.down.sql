-- =====================================================================
-- DOWN 1/3: restore v_influence_headline
-- =====================================================================
-- Reverses 2026-09-02_drop_v_influence_headline.sql.
--
-- The definition below is copied verbatim from docs/schema.sql as
-- captured on 2026-09-02, including the grant that DROP discarded.
--
-- WARNING: this restores the BROKEN view. It returns $39,237,605.53
-- where f_influence_headline returns $11,842,231.76 for the same
-- snapshot and the same 228 deals. Restore it only to unblock something
-- that turned out to read it, and repoint that consumer at
-- f_influence_headline rather than leaving this in place.
--
-- Fully reversible. No data is touched, only a view definition.
-- =====================================================================


-- ============================== PASTE 1 ==============================

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

grant select on mktg.v_influence_headline to authenticated;

-- ============================ END PASTE 1 ============================


-- ============================== PASTE 2 ==============================
-- Verification. Run separately, after PASTE 1.

-- (a) expect exactly one row, one column, value 1
select count(*) as should_be_one
  from information_schema.views
 where table_schema = 'mktg'
   and table_name   = 'v_influence_headline';

-- (b) expect exactly one row: 228 | 228 | 39237605.53
--     the wrong number is the correct result here, it proves the prior
--     definition is back
select total_deals, deals_clean, influenced_pipeline
  from mktg.v_influence_headline;

-- ============================ END PASTE 2 ============================
