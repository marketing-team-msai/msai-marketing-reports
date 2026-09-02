# MSAI Marketing Reports - complete guide

This repo is a small, self-contained system that builds three marketing
reports, publishes them to a private Supabase Storage bucket, and records their
headline numbers to Supabase history tables in the same project. It runs once a day, on a
schedule, with no one running anything by hand and no machine that has to be
switched on.

It is plain automation. There is no AI in the data path and it costs nothing
to run. It reads data from HubSpot, builds Excel workbooks, uploads them to
object storage, and writes a row of numbers to Postgres. That is the whole job.

Windsor.ai is a second source, but only for the standalone
`generate_report.py` run, which pulls ad spend when given a key. The daily
sync into the `mktg` schema does not touch it: `sync_to_mktg.py` never calls
`pull_windsor()`, the workflow passes no `WINDSOR_*`, and `snap_ad_source`
exists with 0 rows. That ETL leg is unbuilt, not retired. See CLAUDE.md.

Publishing to the Marketing SharePoint site is still supported and still in the
code, but it is off by default, because it is the only part that needs a
credential somebody else has to grant. See section 9.

This document is written so that someone who has never seen it before,
including after the original owner has left, can understand what it does and
rebuild it from scratch.

**Setting this up for the first time? Read `SETUP.md` instead.** This file
explains what the system is. `SETUP.md` is the step-by-step.

---

## 1. What it produces

Three Excel workbooks, refreshed every morning.

**A. Pipeline Influence** (`MSAI_Pipeline_Influence_Report.xlsx`)
Shows which marketing campaigns touched which deals. Six tabs: an executive
summary, a campaign influence map (one row per deal and influenced contact), a
per-campaign summary, deal contact details, multi-touch contacts, and
ad-source performance from Windsor.ai. Attribution is "even-split": for each
deal-and-influenced-contact pairing, the deal's value is divided across that
contact's campaigns. Because of that split, the per-campaign column adds up to
more than the plain influenced total; the TOTAL row is the de-duplicated
figure.

**B. Marketing Net New / Sourced** (`MSAI_NetNew_Sourced_Report.xlsx`)
Shows new pipeline that marketing created or influenced, at two levels. The
deal level treats a deal as "sourced" by a program when every marketing
campaign that touched it maps to a single program bucket (Content &
Technology, Events, Advertising, or PR & Brand). The contact level counts
contacts created since the start date that belong to at least one Campaign
Influence list, arranged by lifecycle stage. Scope excludes Amazon and
isolates Galco, per the marketing team's definitions.

**C. Lead Pipeline SLA** (`MSAI_Lead_Pipeline_SLA.xlsx`)
Flags leads sitting too long in a stage. "Days in status" is measured from the
lead-status property history (when the lead actually entered its current
status), not the record's last-modified date, which resets on any edit and
would make stale leads look fresh. The day limits per stage are set in the
workflow file (`SLA_DAYS_*`) so the business can change the rule without a
code change. The worked pipeline (Sales Accepted Lead, MQL, SQL, Opportunity)
is measured; the raw top-of-funnel Lead stage is excluded so per-rep averages
reflect a real working book.

All three read HubSpot **read-only**. Nothing is ever written back to HubSpot.
The SLA report is the only one that needs the `crm.objects.owners.read` scope,
which it uses to turn owner ids into rep names.

PowerPoint decks were part of this system until 31 August 2026 and have been
retired. Workbooks only.

## 2. Where the output goes

**Files.** Every run publishes each workbook to two places in the private
`reports` bucket, under `<Report Name>/`:

- A **current** copy with a fixed filename (for example
  `MSAI_Pipeline_Influence_Report.xlsx`). Overwritten each run, so the name
  never changes and any link or embedded view always shows the latest numbers.
- A dated **Archive** copy under an `Archive/` subfolder (for example
  `Archive/2026-08-31_MSAI_Pipeline_Influence_Report.xlsx`). Never
  overwritten, so these build a full history of files.

Nothing is ever deleted, which means the `Archive/` folders grow. See section
7 for when that matters.

The bucket is private. These workbooks carry deal-level pipeline data, so there
is no public URL. Files are reached from the Supabase dashboard, or through the
time-limited signed link each run prints into its log.

**Numbers.** Each run also writes the headline numbers to Postgres tables in
the same project, one row per report per day. This is the queryable history: trends by month,
campaign performance over time, SLA drift by rep. The Archive folder gives you
the files; Supabase answers questions across them. See section 6.

Reports are written to a local `output/` folder on the runner first, but that
is only a staging area before upload, and it is discarded when the run ends.

## 3. How and when it runs

A GitHub Actions workflow (`.github/workflows/daily-reports.yml`) runs the
whole thing once a day at **11:00 UTC**, which is 6:00 AM US Central in summer
and 5:00 AM in winter. GitHub cron does not follow daylight saving.

There is no machine involved and nothing to leave switched on. To run it early,
use the **Run workflow** button on the repo's Actions tab.

## 4. What is in this repo

You do not need to read the code, but here is what each piece is for.

- `run_all_reports.py` - the main program the daily job runs. Runs the three
  reports, then publishes the workbooks. Holds both publish backends
  (Supabase Storage and SharePoint); `PUBLISH_TARGET` picks which run.
- `generate_report.py` - builds the Pipeline Influence report.
- `generate_netnew_report.py` - builds the Net New / Sourced report.
- `generate_sla_report.py` - builds the Lead Pipeline SLA report.
- `push_history.py` - reads the numbers the three reports just produced and
  upserts them into the Supabase history tables. Calls no external data
  source, so Supabase always matches the workbooks.
- `supabase_schema.sql` - creates the history tables and the trend views. Run
  once, in the Supabase SQL editor.
- `requirements.txt` - the free Python components the job installs.
- `config.env.example` - the credentials template, for running on your own
  machine. **Not the live file.** The scheduled cloud run does not use it at
  all; it builds `config.env` from GitHub secrets at run time and deletes it
  afterwards.
- `SETUP.md` - step-by-step first-time setup.

Created automatically at run time and never committed: `output/` (local
copies), `logs/` (a dated log per month), and `config.env`.
`prior_snapshot.json` is committed back to the repo after each run, because
that is how the Pipeline Influence report computes week-over-week change and
cloud runners are wiped between runs.

## 5. Credentials - what each one is and where it comes from

Four secret values on the default path, held as **GitHub repository secrets**
(Settings > Secrets and variables > Actions). Nothing lives in a file on
anyone's machine.

1. `HUBSPOT_TOKEN` - a HubSpot private-app token with five **read-only** scopes:
   `crm.lists.read`, `crm.objects.contacts.read`, `crm.objects.companies.read`,
   `crm.objects.deals.read` and `crm.objects.owners.read`. Created by a HubSpot
   admin under Settings > Integrations > Private Apps. The owners scope is only
   used by the SLA report, which calls `GET /crm/v3/owners` first to resolve rep
   names; without it that report fails immediately with a 403 while the other
   two succeed.
2. `WINDSOR_API_KEY` - the API key from the Windsor.ai account.
3. `SUPABASE_URL` and `SUPABASE_SERVICE_KEY` - from Supabase, Settings > API.
   Use the **service_role** key, not the anon key. It bypasses row-level
   security, which is why the job can write to the bucket and the tables while
   a browser app cannot.

Three more are needed only when publishing to SharePoint (section 9):
`MSAI_TENANT_ID`, `MSAI_CLIENT_ID`, `MSAI_CLIENT_SECRET`, from IT.

Non-secret settings live in plain sight in the workflow file: `PUBLISH_TARGET`,
the bucket name, the HubSpot portal and folder ids, the pipeline id, the start
date, the Windsor date window, and the SLA day thresholds. Change the SLA numbers if the business
rule changes; leave the rest unless told otherwise.

## 6. The history tables

Seven tables, created by `supabase_schema.sql`:

| Table | Grain |
|---|---|
| `report_runs` | one row per report per day, the run log |
| `influence_history` | one row per day, Pipeline Influence headline numbers |
| `influence_campaign_history` | one row per campaign per day |
| `netnew_history` | one row per day, Net New headline numbers |
| `netnew_program_history` | one row per program per day |
| `sla_history` | one row per lead status per day |
| `sla_rep_history` | one row per rep per lead status per day |

Primary keys include `run_date`, so re-running a report on the same day
overwrites that day rather than creating a duplicate.

Five views sit on top (`v_influence_trend`, `v_campaign_trend`,
`v_netnew_trend`, `v_program_trend`, `v_sla_trend`, plus
`v_influence_monthly`). They already compute period-over-period change, so a
query or a dashboard never has to. Row-level security is on with no permissive
policy: only the service_role key can read or write until someone adds a
policy deliberately.

## 7. If something goes wrong

Open the Actions tab, click the failed run, click the `reports` job, and read
the log.

- **Reports fail before any upload.** Almost always the HubSpot token: expired,
  revoked, or missing one of the five scopes.
- **One report 403s while the others say `ok`.** A missing scope, not a bad
  token. `FAIL   Lead Pipeline SLA after 0s` with a 403 means
  `crm.objects.owners.read` is missing. Add it to the private app and re-run;
  editing scopes does not change the token.
- **`no Supabase credentials`, `failed=3`.** `SUPABASE_URL` or
  `SUPABASE_SERVICE_KEY` is missing or misspelled in the GitHub secrets.
- **Uploads fail with a `403`.** Almost certainly the anon key was pasted
  instead of the service_role key. The anon key cannot write to a private
  bucket.
- **Uploads fail with `413` or a size error.** The project has hit its storage
  quota. Check Settings > Usage, then either move to a paid tier or delete old
  `Archive/` copies.
- **All three fail with a `401` while publishing to SharePoint.** Only relevant
  when `PUBLISH_TARGET` includes sharepoint. The program logged in but is not
  allowed to write. This is a permissions issue on the Microsoft app
  registration, not something in this repo, and section 9 has the ask for IT.
- **`HISTORY reports=3 failed=3`.** Supabase rejected the write. Either the
  service_role key is wrong, or `supabase_schema.sql` was never run. The
  workbooks are unaffected - they were already published before this step.
- **The workflow stopped running on schedule.** Check the Actions tab for a
  banner about disabled schedules, and check that the repo has had a commit in
  the last 60 days.

The `Archive/` folders never get pruned automatically, so storage grows by
roughly half a gigabyte a year. The free tier includes 1 GB. Watch it under
Settings > Usage.

`failed=0` in the log is the only proof the reports were published. Files in
`output/` do not mean it worked - reports are built first and published second,
so you can have local files and a failed upload.

## 8. Security notes

- Secrets live only in GitHub repository secrets. The scheduled run writes them
  into a temporary `config.env` inside the runner, then deletes it in the same
  job. `.gitignore` excludes `config.env` so it cannot be committed by
  accident.
- If a secret is ever exposed, rotate it: regenerate the HubSpot token, the
  Windsor key, the Microsoft client secret, or the Supabase service_role key as
  applicable, then update the GitHub secret.
- The reports are read-only against HubSpot. The only thing this system writes
  to is the Supabase project - the storage bucket and the history tables.
- The storage bucket is private, with no public URL and no anonymous access.
  The workbooks contain deal-level pipeline data, so do not make it public.
  Share individual files with the time-limited signed links the run log prints.
- The Supabase service_role key bypasses row-level security. It belongs in
  GitHub secrets and nowhere else - never in a dashboard, a browser app, or an
  email.
- No AI and no per-run cost: plain code on subscriptions the company already
  has, plus a GitHub Actions schedule and a Supabase project that both fit
  inside free tiers at this volume.

## 9. Publishing to SharePoint

The SharePoint uploader is still in the code, unchanged, and off by default. It
is the only part of this system that needs a credential someone else has to
grant, which is why it is no longer on the main path.

Set `PUBLISH_TARGET` in the workflow's "Write config.env" step to `sharepoint`
(SharePoint only) or `both`, and add `MSAI_TENANT_ID`, `MSAI_CLIENT_ID` and
`MSAI_CLIENT_SECRET` as GitHub secrets.

Those come from IT (Elevated Tech). The app registration must be a dedicated
one, not a personal login, because the job runs unattended. It needs an
**application** permission (not delegated) for SharePoint/Graph file access,
admin-consented, and **write** access granted to the specific Marketing
SharePoint site using the least-privilege "Sites.Selected" model. If that
site-level grant is missing, the reports build but every upload fails with a
401, and the `request-id` values in the log are what let IT trace it.

The folder layout is identical on both targets, so nothing about how people
find a report changes when you switch. With `both`, a report counts as
published only if both destinations accepted it.
