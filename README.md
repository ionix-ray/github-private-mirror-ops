# github-private-mirror-ops

_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: `2026-10-10T13:08:36Z`._

## Summary

- Mirrors registered: **14**
- Status: healthy **12** · paused **0** · diverged **0** · failed **2** · archived **0**
- Total upstream stars: **63,033** · forks: **9,435**
- Daily sync: `0 6 * * *` UTC
- Strategy: `fast-forward`

## Mirrors

| Upstream | Private | Branch | Stars | Forks | Lang | Last Push | Status | License | Notes |
|---|---|---|---|---|---|---|---|---|---|
| [Falcon-Forge/PiRanha](https://github.com/Falcon-Forge/PiRanha) | [ionix-ray/PiRanha](https://github.com/ionix-ray/PiRanha) | `main` | 5 | 10 | TypeScript | 2026-06-20 | ok | MIT |  |
| [google-antigravity/antigravity-sdk-python](https://github.com/google-antigravity/antigravity-sdk-python) | [ionix-ray/antigravity-sdk-python](https://github.com/ionix-ray/antigravity-sdk-python) | `main` | 3,658 | 1,451 | Python | 2026-10-07 | ok | Apache-2.0 |  |
| [maximhq/bifrost](https://github.com/maximhq/bifrost) | [ionix-ray/bifrost](https://github.com/ionix-ray/bifrost) | `dev` | 8,619 | 1,354 | Go | 2026-10-07 | ok | Apache-2.0 |  |
| [carbon-design-system/carbon-charts](https://github.com/carbon-design-system/carbon-charts) | [ionix-ray/carbon-charts](https://github.com/ionix-ray/carbon-charts) | `main` | 1,055 | 219 | HTML | 2026-10-05 | ok | Apache-2.0 |  |
| [belt-sh/cli](https://github.com/belt-sh/cli) | [ionix-ray/cli](https://github.com/ionix-ray/cli) | `main` | 7 | 0 | Shell | 2026-09-27 | ok | MIT |  |
| [experientiallabs/experiential-enterprise](https://github.com/experientiallabs/experiential-enterprise) | [ionix-ray/experiential-enterprise](https://github.com/ionix-ray/experiential-enterprise) | `main` | 0 | 0 | - | - | deleted | unknown | upstream deleted |
| [experientiallabs/experiential](https://github.com/experientiallabs/experiential) | [ionix-ray/experiential](https://github.com/ionix-ray/experiential) | `main` | 9,571 | 234 | Python | 2026-10-08 | deleted | Apache-2.0 | upstream deleted |
| [Portkey-AI/models](https://github.com/Portkey-AI/models) | [ionix-ray/models](https://github.com/ionix-ray/models) | `main` | 143 | 42 | JavaScript | 2026-10-08 | ok | MIT |  |
| [Portkey-AI/openapi](https://github.com/Portkey-AI/openapi) | [ionix-ray/openapi](https://github.com/ionix-ray/openapi) | `master` | 7 | 7 | - | 2026-09-30 | ok | MIT |  |
| [pixie-io/pixie](https://github.com/pixie-io/pixie) | [ionix-ray/pixie](https://github.com/ionix-ray/pixie) | `main` | 6,546 | 506 | C++ | 2026-10-08 | ok | Apache-2.0 |  |
| [Qiskit/qiskit](https://github.com/Qiskit/qiskit) | [ionix-ray/qiskit](https://github.com/ionix-ray/qiskit) | `main` | 7,871 | 3,074 | Python | 2026-10-08 | ok | Apache-2.0 |  |
| [kyegomez/swarms](https://github.com/kyegomez/swarms) | [ionix-ray/swarms](https://github.com/ionix-ray/swarms) | `master` | 7,234 | 1,038 | Python | 2026-10-07 | ok | Apache-2.0 |  |
| [vtmocanu/uzi](https://github.com/vtmocanu/uzi) | [ionix-ray/uzi](https://github.com/ionix-ray/uzi) | `main` | 87 | 4 | Go | 2026-10-08 | ok | MIT |  |
| [gfx-rs/wgpu](https://github.com/gfx-rs/wgpu) | [ionix-ray/wgpu](https://github.com/ionix-ray/wgpu) | `trunk` | 18,230 | 1,496 | Rust | 2026-10-07 | ok | Apache-2.0 |  |

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
