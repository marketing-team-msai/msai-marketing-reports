-- =====================================================================
-- SEED: event_editor + first real event (The Reliability Conference)
-- =====================================================================
-- Run this AFTER 2026-09-14_events_page.sql. Not a schema change - just
-- data - so no .down.sql; to remove, delete the rows by event_id / email.
--
-- Confirmed with Alecia 2026-09-14:
--   - event_editor: herself + katie.stine@multisensorai.com
--   - The Reliability Conference maps to TWO HubSpot Campaign Influence
--     lists, both verified live against HubSpot 2026-09-14:
--       list 4662  "... - San Fran - Booth"        35 members
--       list 4661  "... - San Fran - Collateral"     0 members
--     (0 members on Collateral is real, not an error - nothing has been
--     tagged into that list yet. generate_events_report.py will pick it
--     up automatically once contacts are added.)
--
-- event_date, location, event_type, actual_attendees, and actual_cost
-- below are carried over from MSAI_Tradeshow_ROI_Model_v2_4_20260810.xlsx,
-- Master Table row 4 ("The Reliability Conf (TRC)") - same event, same
-- city. The HubSpot-verified names_captured (35, above) matches that
-- workbook's row exactly, which is a good sign the two are the same show.
-- budget_cost is NOT in the workbook (it only ever tracked actual cost) -
-- left null here; fill it in once you have the planned budget figure.
-- =====================================================================

insert into mktg.event_editor (email) values
    ('alecia.obrien@multisensorai.com'),
    ('katie.stine@multisensorai.com')
on conflict (email) do nothing;

insert into mktg.event
    (event_id, event_name, event_date, event_type, location, actual_attendees)
values
    ('trc-2026-sf', 'The Reliability Conference', '2026-05-19', 'Conference',
     'San Francisco, CA', 350)
on conflict (event_id) do update
    set event_name       = excluded.event_name,
        event_date        = excluded.event_date,
        event_type        = excluded.event_type,
        location          = excluded.location,
        actual_attendees  = excluded.actual_attendees;

insert into mktg.event_hubspot_list (event_id, hubspot_list_id, label) values
    ('trc-2026-sf', '4662', 'Booth'),
    ('trc-2026-sf', '4661', 'Collateral')
on conflict (event_id, hubspot_list_id) do update
    set label = excluded.label;

insert into mktg.event_cost (event_id, budget_cost, actual_cost, cost_notes)
values
    ('trc-2026-sf', null, 14813.59,
     'actual_cost carried over from MSAI_Tradeshow_ROI_Model_v2_4_20260810.xlsx, '
     'Master Table row 4 (fully-loaded cost). budget_cost not yet entered.')
on conflict (event_id) do update
    set actual_cost = excluded.actual_cost,
        cost_notes  = excluded.cost_notes;


-- Verify: expected 1 row, names_captured 35 (once generate_events_report.py
-- has run at least once - see sync_to_mktg.py --only events), actual_cost
-- 14813.59, budget_cost null, budget_status null (no budget entered yet).
-- select * from mktg.v_event_roi where event_id = 'trc-2026-sf'
-- order by snapshot_date desc limit 1;
