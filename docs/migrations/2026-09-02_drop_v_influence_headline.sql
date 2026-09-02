-- =====================================================================
-- mktg: drop v_influence_headline
-- =====================================================================
-- NOT APPLIED. Unblocked: nothing reads this view.
--
-- The view returned $39,237,605.53 for the same snapshot and the same 228
-- deals where f_influence_headline returns $11,842,231.76. It looked like
-- it deduplicated and did not:
--
--   JOIN LATERAL (SELECT DISTINCT ON (s2.deal_id) s2.amount_home
--                   FROM snap_influence s2
--                  WHERE s2.snapshot_date = s.snapshot_date
--                    AND s2.deal_id = s.deal_id) ON true
--
-- The lateral is already scoped to one deal_id, so DISTINCT ON has
-- nothing to collapse and the join is 1:1. sum() then ran once per
-- snap_influence row, all 359 of them, which is the naive row sum.
--
-- Dropped rather than repaired. f_influence_headline answers the same
-- question correctly and carries the include_amazon parameter the
-- Overview tile already uses. Two objects answering one question from two
-- bodies is a permanent trap; repairing it preserves the trap in working
-- order.
--
-- Confirmed unread: /overview's Influenced Pipeline tile calls
-- f_influence_headline(include_amazon) as an RPC. No page queries the
-- view.
--
-- Run inside an explicit transaction. Apply, run the verification block,
-- and only commit if every figure matches.
-- =====================================================================

begin;

drop view if exists mktg.v_influence_headline;


-- =====================================================================
-- VERIFICATION. Expected values are for snapshot 2026-09-02.
-- =====================================================================

-- (a) the view is gone
select count(*) from information_schema.views
 where table_schema = 'mktg' and table_name = 'v_influence_headline';
--   0

-- (b) the function that replaces it is untouched and still correct
select total_deals, influenced_pipeline
  from mktg.f_influence_headline(true);
--   228, 11842231.76

-- commit;
-- rollback;
