# github-private-mirror-ops

_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: `2026-07-12T17:53:37Z`._

## Summary

- Mirrors registered: **6**
- Status: healthy **6** · paused **0** · diverged **0** · failed **0** · archived **0**
- Total upstream stars: **0** · forks: **0**
- Daily sync: `0 6 * * *` UTC
- Strategy: `fast-forward`

## Mirrors

| Upstream | Private | Branch | Stars | Forks | Lang | Last Push | Status | License | Notes |
|---|---|---|---|---|---|---|---|---|---|
| [Falcon-Forge/PiRanha](https://github.com/Falcon-Forge/PiRanha) | [ionix-ray/PiRanha](https://github.com/ionix-ray/PiRanha) | `main` | 0 | 0 | - | - | (pending) | MIT |  |
| [carbon-design-system/carbon-charts](https://github.com/carbon-design-system/carbon-charts) | [ionix-ray/carbon-charts](https://github.com/ionix-ray/carbon-charts) | `main` | 0 | 0 | - | - | (pending) | Apache-2.0 |  |
| [belt-sh/cli](https://github.com/belt-sh/cli) | [ionix-ray/cli](https://github.com/ionix-ray/cli) | `main` | 0 | 0 | - | - | (pending) | MIT |  |
| [pixie-io/pixie](https://github.com/pixie-io/pixie) | [ionix-ray/pixie](https://github.com/ionix-ray/pixie) | `main` | 0 | 0 | - | - | (pending) | Apache-2.0 |  |
| [Qiskit/qiskit](https://github.com/Qiskit/qiskit) | [ionix-ray/qiskit](https://github.com/ionix-ray/qiskit) | `main` | 0 | 0 | - | - | (pending) | Apache-2.0 |  |
| [gfx-rs/wgpu](https://github.com/gfx-rs/wgpu) | [ionix-ray/wgpu](https://github.com/ionix-ray/wgpu) | `trunk` | 0 | 0 | - | - | (pending) | Apache-2.0 |  |

## License Change Log

_No license changes detected so far._

## Architecture

- **Intent** (what to mirror) lives in `tracker/registry/<owner>__<repo>.json` — one file per mirror, human/PR-owned. Registration adds a new file, so it never conflicts.
- **Metadata** (observed upstream state) lives in `tracker/metadata/<owner>__<repo>.json` — bot-owned, written only by workflows.
- **Read-model** `repo-status.json` joins both and is what `index.html` and this dashboard render.
- Schemas: `tracker/schemas/`. Config (version + defaults): `tracker/config.json`.

## Workflows

- **New Private Fork** — `Actions → New Private Fork` (manual, input-driven). Opens a registration PR that adds one intent file.
- **Sync Status Dashboard** — auto-runs on PR merge + daily cron. Writes only metadata + generated files.

## Operating model

- Strategy: **fast-forward only**. Divergence triggers an issue + auto-pause; never force-pushes.
- Secrets: per-owner classic PATs stored as `GH_SYNC_PAT_<OWNER>`. Never accepted via dispatch inputs.
- Registry: intent files under `tracker/registry/` are the source of truth for what is mirrored. Metadata is a cache of upstream reality, refreshed by the bot.
- For a rich interactive dashboard, open `index.html` locally (reads `repo-status.json`).
