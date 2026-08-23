# github-private-mirror-ops

_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: `2026-08-23T07:24:11Z`._

## Summary

- Mirrors registered: **7**
- Status: healthy **1** · paused **0** · diverged **6** · failed **0** · archived **0**
- Total upstream stars: **36,196** · forks: **6,360**
- Daily sync: `0 6 * * *` UTC
- Strategy: `fast-forward`

## Mirrors

| Upstream | Private | Branch | Stars | Forks | Lang | Last Push | Status | License | Notes |
|---|---|---|---|---|---|---|---|---|---|
| [Falcon-Forge/PiRanha](https://github.com/Falcon-Forge/PiRanha) | [ionix-ray/PiRanha](https://github.com/ionix-ray/PiRanha) | `main` | 5 | 10 | - | 2026-06-20 | ok | MIT |  |
| [google-antigravity/antigravity-sdk-python](https://github.com/google-antigravity/antigravity-sdk-python) | [ionix-ray/antigravity-sdk-python](https://github.com/ionix-ray/antigravity-sdk-python) | `main` | 3,087 | 1,218 | Python | 2026-08-13 | diverged | Apache-2.0 |  |
| [carbon-design-system/carbon-charts](https://github.com/carbon-design-system/carbon-charts) | [ionix-ray/carbon-charts](https://github.com/ionix-ray/carbon-charts) | `main` | 1,045 | 218 | HTML | 2026-07-31 | diverged | Apache-2.0 |  |
| [belt-sh/cli](https://github.com/belt-sh/cli) | [ionix-ray/cli](https://github.com/ionix-ray/cli) | `main` | 6 | 0 | Shell | 2026-07-13 | diverged | MIT |  |
| [pixie-io/pixie](https://github.com/pixie-io/pixie) | [ionix-ray/pixie](https://github.com/ionix-ray/pixie) | `main` | 6,516 | 499 | C++ | 2026-07-30 | diverged | Apache-2.0 |  |
| [Qiskit/qiskit](https://github.com/Qiskit/qiskit) | [ionix-ray/qiskit](https://github.com/ionix-ray/qiskit) | `main` | 7,715 | 3,014 | Python | 2026-08-19 | diverged | Apache-2.0 |  |
| [gfx-rs/wgpu](https://github.com/gfx-rs/wgpu) | [ionix-ray/wgpu](https://github.com/ionix-ray/wgpu) | `trunk` | 17,822 | 1,401 | Rust | 2026-08-19 | diverged | Apache-2.0 |  |

## License Change Log

_No license changes detected so far._

## Architecture

- **Intent** (what to mirror) lives in `tracker/registry/<owner>__<repo>.json` — one file per mirror, human/PR-owned. Registration adds a new file, so it never conflicts.
- **Metadata** (observed upstream state) lives in `tracker/metadata/<owner>__<repo>.json` — bot-owned, written only by workflows.
- **Read-model** `repo-status.json` joins both and is what `index.html` and this dashboard render.
- Schemas: `tracker/schemas/`. Config (version + defaults): `tracker/config.json`.

## Workflows

- **New Private Fork** — `Actions → New Private Fork` (manual, input-driven). Pick where the private mirror lands via the **owner dropdown** (config-driven in `tracker/owners.json`); opens a registration PR that adds one intent file.
- **Bulk Import** — import many repos at once (manual, comma-separated list).
- **Sync Mirrors** — daily cron (fast-forward only). Pushes upstream changes into each private mirror; divergence opens an issue + auto-pause PR.
- **Sync Status Dashboard** — auto-runs on PR merge + daily cron. Writes only metadata + generated files.

## Operating model

- Strategy: **fast-forward only**. Divergence triggers an issue + auto-pause; never force-pushes.
- Owners: `tracker/owners.json` maps every dropdown owner to its PAT secret + environment. `tests/test-owners.sh` fails on dropdown/config drift.
- Secrets: per-owner PATs stored under the names in `tracker/owners.json`. Never accepted via dispatch inputs.
- Registry: intent files under `tracker/registry/` are the source of truth for what is mirrored. Metadata is a cache of upstream reality, refreshed by the bot.
- For a rich interactive dashboard, open `index.html` locally (reads `repo-status.json`).
