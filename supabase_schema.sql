-- =====================================================================
-- MSAI marketing reporting - history tables
-- =====================================================================
-- Run this ONCE in the Supabase SQL Editor. Safe to re-run: every
-- statement is IF NOT EXISTS or CREATE OR REPLACE.
--
-- One row per report run per grain. run_date is the primary key part,
-- so re-running a report on the same day overwrites that day rather
-- than creating a duplicate.
--
-- Nothing here is customer-facing and nothing is exposed publicly:
-- RLS is on with no permissive policy, so only the service-role key
-- (used by push_history.py) can read or write. Add a read policy later
-- if a dashboard needs anon access.
-- =====================================================================

-- ---------------------------------------------------------- run log ----
create table if not exists report_runs (
  run_date      date        not null,
  report        text        not null,
  generated_at  timestamptz not null,
  rows_written  integer,
  primary key (run_date, report)
);

-- ------------------------------------------- pipeline influence --------
create table if not exists influence_history (
  run_date          date primary key,
  generated_at      timestamptz not null,
  label             text,
  total_deals       integer,
  total_value       numeric(14,2),
  influenced_deals  integer,
  influenced_value  numeric(14,2),
  influenced_pct    numeric(6,2),
  producing_campaigns integer,
  multitouch_contacts integer,
  contacts_mapped   integer,
  windsor_paid_spend numeric(14,2)
);

create table if not exists influence_campaign_history (
  run_date       date not null,
  campaign_name  text not null,
  campaign_type  text,
  contacts       integer,
  deals          integer,
  value          numeric(14,2),
  primary key (run_date, campaign_name)
);

-- ------------------------------------------ net new / sourced ----------
create table if not exists netnew_history (
  run_date          date primary key,
  generated_at      timestamptz not null,
  sourced_deals     integer,
  sourced_pipeline  numeric(14,2),
  won_deals         integer,
  won_value         numeric(14,2),
  share_2027        numeric(8,4),
  share_h2_build    numeric(8,4),
  sourced_contacts  integer,
  galco_deals       integer,
  galco_sourced     numeric(14,2),
  influenced_non_amazon_deals integer,
  net_new_deals_in_window     integer
);

create table if not exists netnew_program_history (
  run_date   date not null,
  program    text not null,
  deals      integer,
  sourced    numeric(14,2),
  won        numeric(14,2),
  won_deals  integer,
  primary key (run_date, program)
);

-- ------------------------------------------------ lead pipeline SLA ----
create table if not exists sla_history (
  run_date          date not null,
  lead_status       text not null,
  total             integer,
  over_sla          integer,
  pct_over          numeric(6,2),
  avg_age_days      numeric(8,2),
  median_age_days   numeric(8,2),
  sla_days          integer,
  generated_at      timestamptz not null,
  primary key (run_date, lead_status)
);

create table if not exists sla_rep_history (
  run_date     date not null,
  owner        text not null,
  lead_status  text not null,
  total        integer,
  over_sla     integer,
  primary key (run_date, owner, lead_status)
);

-- ----------------------------------------------------------- RLS -------
alter table report_runs                enable row level security;
alter table influence_history          enable row level security;
alter table influence_campaign_history enable row level security;
alter table netnew_history             enable row level security;
alter table netnew_program_history     enable row level security;
alter table sla_history                enable row level security;
alter table sla_rep_history            enable row level security;

-- ------------------------------------------------- trend views ---------
-- These are what a dashboard reads later. Building them here means the
-- dashboard only ever renders rows, never computes them.

create or replace view v_influence_trend as
select run_date,
       total_deals,
       total_value,
       influenced_deals,
       influenced_value,
       influenced_pct,
       influenced_value - lag(influenced_value) over (order by run_date) as influenced_value_change,
       influenced_deals - lag(influenced_deals) over (order by run_date) as influenced_deals_change
from influence_history
order by run_date;

create or replace view v_campaign_trend as
select campaign_name,
       campaign_type,
       run_date,
       deals,
       value,
       value - lag(value) over (partition by campaign_name order by run_date) as value_change
from influence_campaign_history
order by campaign_name, run_date;

create or replace view v_netnew_trend as
select run_date,
       sourced_deals,
       sourced_pipeline,
       won_value,
       share_2027,
       sourced_contacts,
       sourced_pipeline - lag(sourced_pipeline) over (order by run_date) as sourced_pipeline_change
from netnew_history
order by run_date;

create or replace view v_program_trend as
select program, run_date, deals, sourced, won,
       sourced - lag(sourced) over (partition by program order by run_date) as sourced_change
from netnew_program_history
order by program, run_date;

create or replace view v_sla_trend as
select run_date, lead_status, total, over_sla, pct_over, avg_age_days,
       pct_over - lag(pct_over) over (partition by lead_status order by run_date) as pct_over_change
from sla_history
order by lead_status, run_date;

-- Month-end snapshot: the last run of each calendar month. This is the
-- one to chart when a daily line is too noisy.
create or replace view v_influence_monthly as
select distinct on (date_trunc('month', run_date))
       date_trunc('month', run_date)::date as month,
       run_date, total_value, influenced_value, influenced_deals, influenced_pct
from influence_history
order by date_trunc('month', run_date), run_date desc;
