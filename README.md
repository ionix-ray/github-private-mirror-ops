# github-private-mirror-ops

_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: `2026-06-18T17:38:39Z`._

## Summary

- Mirrors registered: **0**
- Status: healthy **0** · paused **0** · diverged **0** · failed **0** · archived **0**
- Total upstream stars: **0** · forks: **0**
- Daily sync: `0 6 * * *` UTC
- Strategy: `fast-forward`

## Mirrors

_No mirrors registered yet. Run **Actions → New Private Fork** to add one._

## Workflows

- **New Private Fork** — `Actions → New Private Fork` (manual, input-driven)
- **Sync Status Dashboard** — auto-runs on PR merge + daily cron
- **Sync Mirrors** — daily 06:00 UTC (Phase 2, coming)
- **Migrate Public Forks** — bulk one-shot (Phase 3, coming)

## Operating model

- Strategy: **fast-forward only**. Divergence triggers an issue + auto-pause; never force-pushes.
- Secrets: per-owner classic PATs stored as `GH_SYNC_PAT_<OWNER>`. Never accepted via dispatch inputs.
- Registry: this dashboard is rendered from `.github/synced-repos.yml`. That file is the source of truth.
- For a rich interactive dashboard, open `index.html` locally (reads `repo-status.json`).
