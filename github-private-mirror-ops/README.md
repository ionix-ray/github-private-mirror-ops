# github-private-mirror-ops

_Live state dashboard. Auto-generated — do not hand-edit. Will be refreshed by workflows on first run._

## Summary

- Mirrors registered: **0**
- Status: healthy **0** · paused **0** · diverged **0** · failed **0**
- Daily sync: `0 6 * * *` UTC
- Strategy: `fast-forward`

## Mirrors

_No mirrors registered yet. Run **Actions → New Private Fork** to add one._

## License Change Log

_No license changes detected so far._

## Workflows

- **New Private Fork** — `Actions → New Private Fork` (manual, input-driven)
- **Sync Mirrors** — daily 06:00 UTC (Phase 2, coming)
- **Migrate Public Forks** — bulk one-shot (Phase 3, coming)

## Operating model

- Strategy: **fast-forward only**. Divergence triggers an issue + auto-pause; never force-pushes.
- Secrets: per-owner classic PATs stored as `GH_SYNC_PAT_<OWNER>`. Never accepted via dispatch inputs.
- Registry: this dashboard is rendered from `.github/synced-repos.yml`. That file is the source of truth.

## First-time setup

1. Create two classic PATs (one per owner): scopes `repo, workflow, delete_repo`.
   - PAT created by `samirparhi-dev` user → stored as repo secret `GH_SYNC_PAT_SAMIRPARHI_DEV`.
   - PAT created by a user with `cyfen-code` org membership → stored as repo secret `GH_SYNC_PAT_CYFEN_CODE`.
2. Add both via **Settings → Secrets and variables → Actions → New repository secret**.
3. Run **Actions → New Private Fork** with a small public repo to smoke-test.

> ⚠️ Never paste a PAT into a workflow_dispatch input. PATs are repo secrets only.
