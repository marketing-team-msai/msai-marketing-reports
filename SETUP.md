# Setup - moving MSAI Marketing Reports to the cloud

Nine steps. The three Excel workbooks get built on a daily cloud schedule and
published to a private Supabase bucket, with their headline numbers recorded to
Supabase history tables at the same time.

**There is no IT dependency.** Everything here is done with accounts you
control. SharePoint is still supported if you want it later, but it is not part
of the main path any more - see the appendix.

Steps 2 and 3 are unchanged from the earlier version of this guide, so if you
have already created the repo and started pushing, carry straight on.

---

## What changed from the old setup

| Old (lost drive) | New |
|---|---|
| Windows Scheduled Task, 6:00 AM | GitHub Actions cron, 11:00 UTC |
| `config.env` on disk | GitHub repo secrets, written at run time |
| Ran only if the machine was awake | Runs regardless, no machine involved |
| `logs/` folder on the machine | Run log in the Actions tab, kept 30 days |
| `prior_snapshot.json` on disk | Committed back to the repo each run |
| PowerPoint decks on Mondays | Removed |
| Workbooks published to SharePoint | Published to a private Supabase bucket |
| Microsoft app registration from IT | Not needed |
| History was dated files only | Dated files **and** queryable rows |

Report logic and HubSpot calls are unchanged. What changed is where the
finished workbooks land.

**Do not skip step 8.** It is the only step that proves the whole thing works.

---

# Part 1 - Get the reports running

## Step 1. Get the two API keys

Only two, and you can get both yourself.

**a. HubSpot token**

HubSpot > Settings (gear) > Integrations > Private Apps. Find the existing app
for reporting and delete it - it was tied to the lost drive - then create a new
one. Give it these four scopes, all read-only, and nothing else:

- `crm.lists.read`
- `crm.objects.contacts.read`
- `crm.objects.companies.read`
- `crm.objects.deals.read`

Copy the token when it is shown. You cannot see it again after you close that
screen. Paste it somewhere temporary for now.

**b. Windsor.ai key**

Windsor.ai account > API settings. Copy the key. If nobody knows the Windsor
login, the reports still run - only the ad-source tab of the Pipeline Influence
report goes blank.

That is the whole credential list. The HubSpot portal id, list folder id,
pipeline id, start date, and SLA thresholds are already filled into the
workflow file.

## Step 2. Create the GitHub repo

Go to github.com, in the MSAI organization, and create a new repository:

- Name: `msai-marketing-reports`
- Visibility: **Private**
- Do not add a README, .gitignore, or license - this folder already has them

Leave the page open. You need the URL it shows you.

## Step 3. Push this folder to it

Open PowerShell and run these **one line at a time**, in order. Do not join
them with `&&` - Windows PowerShell 5.1 does not accept `&&` as a separator
and will refuse the whole line with a parser error.

```bash
cd "C:\Users\AleciaO'Brien\OneDrive - Infrared Cameras Inc\Documents\Claude\MSAI-Reports"
```

```bash
git init
```

```bash
git add .
```

```bash
git commit -m "MSAI marketing reports, cloud version"
```

```bash
git branch -M main
```

If git says it does not know who you are, run these two once and repeat the
commit:

```bash
git config --global user.email "alecia.obrien@multisensorai.com"
```

```bash
git config --global user.name "Alecia O'Brien"
```

Now replace `<org>` with the GitHub organization name from the URL on your
screen, and run:

```bash
git remote add origin https://github.com/<org>/msai-marketing-reports.git
```

```bash
git push -u origin main
```

If git asks you to sign in, a browser window opens. Sign in with your GitHub
account and it continues on its own.

**Check before moving on:** refresh the GitHub page. You should see the Python
files and a `.github` folder. You should **not** see a `config.env` file
anywhere. `.gitignore` blocks it, along with `output/` and `logs/`, so no
secret and no generated file can be committed by accident.

## Step 4. Create the Supabase project

This is now both where the workbooks live and where the history is kept.

1. supabase.com > sign in > **New project**
2. Name: `msai-marketing-history`
3. Region: pick the US region closest to you (`us-east-1` is fine)
4. Set a database password. Save it in your password manager - you will not
   need it for this setup, but you will regret losing it later.

Free tier is fine to start. See "Watch the storage total" under Living with it
for when that stops being true.

Provisioning takes a couple of minutes.

## Step 5. Create the history tables

1. Left sidebar: **SQL Editor** > **New query**
2. Open `supabase_schema.sql` from this folder, copy all of it, paste it in
3. Click **Run**

You should see "Success. No rows returned." That is correct - it creates
tables, not rows.

Check it worked: left sidebar > **Table Editor**. You should see seven empty
tables (`report_runs`, `influence_history`, `influence_campaign_history`,
`netnew_history`, `netnew_program_history`, `sla_history`, `sla_rep_history`).

The script is safe to re-run if you need to.

You do **not** need to create the storage bucket by hand. The first run creates
it, private, and names it `reports`.

## Step 6. Load the four secrets into GitHub

First get the two Supabase values. In Supabase: **Settings** (gear, bottom
left) > **API**.

- **Project URL** - looks like `https://abcdefgh.supabase.co`
- **service_role** key under Project API keys - click reveal, then copy

Take the **service_role** key, not the **anon** key. The anon key cannot write
to the tables or the bucket, because row-level security is on with no
permissive policy. The service_role key bypasses that, which is exactly why it
is a secret and belongs only in GitHub secrets - never in a file, a dashboard,
or an email.

Then in GitHub: repo > **Settings** > **Secrets and variables** > **Actions** >
**New repository secret**. Add these four, one at a time. Names must match
exactly - capitals, underscores, no spaces:

| Name | Value |
|---|---|
| `HUBSPOT_TOKEN` | from step 1a |
| `WINDSOR_API_KEY` | from step 1b |
| `SUPABASE_URL` | the Project URL |
| `SUPABASE_SERVICE_KEY` | the service_role key |

You cannot read a secret back after saving it. If you mistype one, delete it
and add it again.

## Step 7. First test - build only, nothing published

This proves your HubSpot token works before anything gets written anywhere.

1. Repo > **Actions** tab
2. Left sidebar: **MSAI Marketing Reports**
3. **Run workflow** button on the right
4. Set **dry_run** to `true`. Leave **only** blank.
5. Click the green **Run workflow**

It takes about five minutes. Click into the run, then into the `reports` job,
to watch the log live.

**What good looks like:** the "Run reports" step ends with

```
generated 3/3, published 0/0
```

and a line saying `dry run, nothing published`. Three of three generated is the
proof that HubSpot is working.

**If it fails here**, it is almost always the HubSpot token: either mistyped,
or missing one of the four scopes. Open the log and read the last few red
lines - they name the problem directly.

## Step 8. Second test - the real thing

Same as step 7, but set **dry_run** to `false`.

**What good looks like:** the log shows a `made   bucket reports (private)`
line on this first run only, then `put` lines, a `link` line per report, and
ends with:

```
OUTCOME items_in=3 items_out=3 failed=0
HISTORY reports=3 failed=0
```

`failed=0` on both lines is the proof. Files appearing in `output/` mean the
reports built, not that they published - reports are always built first and
published second.

Then check both halves in Supabase:

- **Storage** > `reports` bucket. Three folders, each with a workbook and an
  `Archive/` subfolder holding today's dated copy.
- **Table Editor** > `influence_history`. Exactly one row, dated today.

Cross-check one number: download the Pipeline Influence workbook, open the exec
summary, and confirm `influenced_value` matches the row in
`influence_history`. It should match exactly, because the history push reads
the numbers the report already computed rather than recalculating anything.

**Setup is complete.** The daily 11:00 UTC schedule now takes over. Nobody has
to run anything and no machine has to be awake.

---

# Part 2 - Getting the files to people

## Step 9. Decide how people read them

The bucket is private on purpose. These workbooks carry deal-level pipeline
data, so there is no public URL and no anonymous link. Four ways to get the
files to people, cheapest first:

**a. Supabase dashboard (works today, no setup).** Storage > `reports` >
click a file > Download. Fine for you and anyone else you add to the Supabase
project. Project members are managed under Settings > Team.

**b. Signed links from the run log (works today).** Every run prints a
`link` line per report - a signed download URL, valid 7 days by default. Paste
one into Teams or an email when someone asks for the current numbers. Change
the window with `SUPABASE_LINK_DAYS` in the workflow file.

**c. Re-enable SharePoint alongside Supabase.** If people are attached to the
old SharePoint folders and IT will grant the permission, see the appendix. You
can publish to both.

**d. The dashboard, later.** See the last section.

Anyone who had a link to the old SharePoint copies will find those files frozen
at their last successful run rather than updating. If someone has one embedded
in a page or a report, either send them a signed link or turn SharePoint back
on for both.

---

# Living with it

## Checking on it

Actions tab. Green check means it ran. Click any run to read the log, or
download the `reports-<number>` artifact to get that day's workbooks and log
without opening Supabase. Artifacts are kept 30 days.

## Running it early

Actions > Run workflow. Same as the old `Start-ScheduledTask` command.

## Running just one report

Actions > Run workflow, and put `influence`, `netnew`, or `sla` in the **only**
box. Useful when you are chasing a problem in one report and do not want to
wait for all three.

## Watch the storage total

Supabase free tier includes 1 GB of storage. Every run adds one dated archive
copy per report and never deletes anything, so the bucket grows steadily -
roughly half a gigabyte a year at typical workbook sizes, though it depends on
how many rows the reports carry.

Check it occasionally under Settings > Usage. When it gets close, either move
to a paid tier or delete archive copies older than a year from the Storage
browser. The `Archive/` folders are the only thing that grows; the fixed-name
current copies are overwritten in place.

## Changing an SLA threshold

The three `SLA_DAYS_*` numbers live in
`.github/workflows/daily-reports.yml`, in the "Write config.env from secrets"
step. Edit them on GitHub directly (pencil icon), commit, and the next run
picks them up. No code change.

## Changing the run time

The cron `0 11 * * *` in the same file. It is UTC, so it lands at 6:00 AM
Central in summer and 5:00 AM in winter - GitHub cron does not follow daylight
saving. If the winter hour bothers anyone, change it to `0 12 * * *` in
November and back in March.

## Useful queries once you have a few weeks of history

SQL Editor. The views were built in step 5 so you do not have to write the
window functions yourself:

```sql
select * from v_influence_trend order by run_date desc limit 30;
```

```sql
select * from v_campaign_trend where campaign_name = 'your campaign' order by run_date;
```

```sql
select * from v_influence_monthly order by month desc;
```

```sql
select * from v_sla_trend where lead_status = 'Qualified' order by run_date desc limit 30;
```

## Things worth knowing

- **The reports never write to HubSpot.** All four HubSpot scopes are
  read-only. The only thing this system writes to is your Supabase project.
- **A same-day re-run overwrites that day** in both the bucket and the tables,
  rather than creating duplicates. Run it as often as you like.
- **A history failure cannot lose you a workbook.** The history push runs after
  the file upload and is marked continue-on-error, so a table problem costs one
  day of history rows and nothing else.
- **`prior_snapshot.json` gets committed** back to the repo after each run.
  That is not noise - it is how the Pipeline Influence report knows last week's
  numbers, and cloud runners are wiped between runs.
- **Scheduled workflows and idle repos.** GitHub disables schedules in public
  repos after 60 days without a commit. Yours is private, and the snapshot
  commit keeps it active anyway.

---

# When you want the dashboard

Do this only after the history tables have a few weeks of rows in them. A
dashboard over three days of data tells you nothing, and you would be paying
Lovable credits to find that out.

Lovable cannot produce .xlsx files, so it does not replace these reports. It
sits alongside them, reading the Supabase views from step 5. It is also the
cleanest answer to step 9 - a dashboard can show the trends and hand people a
download link for the workbook, so nobody needs Supabase access.

The way to keep the credit cost low: **decide the screens first, then build one
SQL view per screen in Supabase, so each view returns exactly the rows that
screen displays.** Then Lovable's only job is to render a table or a line chart
from a view it can read directly. That is one or two prompts per screen instead
of ten rounds of "no, group it by month, not by week." Every aggregation you
push down into SQL is an aggregation you are not paying Lovable to iterate on.

Connect Lovable to Supabase with the **anon** key, not the service_role key,
and add a read-only RLS policy for exactly the views the dashboard needs. Do
not hand a browser app the key that bypasses security.

---

# Appendix - publishing to SharePoint

The SharePoint uploader is still in the code, unchanged. It is off by default
because it is the only part of this system that needs someone else's
permission.

To turn it on, set `PUBLISH_TARGET` in the workflow's "Write config.env" step
to `sharepoint` (SharePoint only) or `both` (both destinations), then add three
more GitHub secrets: `MSAI_TENANT_ID`, `MSAI_CLIENT_ID`, `MSAI_CLIENT_SECRET`.

Those come from IT (Elevated Tech). Ask for the tenant id and client id of the
existing MSAI reporting app registration plus a new client secret with the old
one revoked, and ask them to confirm this is still in place:

> An **application** permission (not delegated) for SharePoint/Graph file
> access, admin-consented, with **write** access to the Marketing SharePoint
> site granted through `Sites.Selected`.

That last line is the one that matters. If the site-level grant is missing, all
three reports build perfectly and every upload fails with a 401. Send IT the
`request-id` values from the log - that is what lets them trace the exact error
on their side. A brand-new grant can take up to an hour to take effect, but
past that it is not propagation.

With `PUBLISH_TARGET=both`, a report counts as published only if both
destinations accepted it, so a SharePoint permission problem will show up as
`failed` in the outcome line even though the Supabase copy went up fine.
