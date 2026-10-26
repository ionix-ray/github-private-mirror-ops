# github-private-mirror-ops

_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: `2026-10-26T13:41:41Z`._

## Summary

- Mirrors registered: **17**
- Status: healthy **16** · paused **0** · diverged **0** · failed **1** · archived **0**
- Total upstream stars: **424,456** · forks: **100,148**
- Daily sync: `0 6 * * *` UTC
- Strategy: `fast-forward`

## Mirrors

| Upstream | Private | Branch | Stars | Forks | Lang | Last Push | Status | License | Notes |
|---|---|---|---|---|---|---|---|---|---|
| [gyoisamurai/GyoiThon](https://github.com/gyoisamurai/GyoiThon) | [ionix-ray/GyoiThon](https://github.com/ionix-ray/GyoiThon) | `master` | 832 | 306 | Python | 2023-04-21 | ok | OTHER |  |
| [Falcon-Forge/PiRanha](https://github.com/Falcon-Forge/PiRanha) | [ionix-ray/PiRanha](https://github.com/ionix-ray/PiRanha) | `main` | 4 | 10 | TypeScript | 2026-06-20 | ok | MIT |  |
| [google-antigravity/antigravity-sdk-python](https://github.com/google-antigravity/antigravity-sdk-python) | [ionix-ray/antigravity-sdk-python](https://github.com/ionix-ray/antigravity-sdk-python) | `main` | 3,814 | 1,505 | Python | 2026-10-13 | ok | Apache-2.0 |  |
| [maximhq/bifrost](https://github.com/maximhq/bifrost) | [ionix-ray/bifrost](https://github.com/ionix-ray/bifrost) | `dev` | 9,004 | 1,443 | Go | 2026-10-21 | ok | Apache-2.0 |  |
| [carbon-design-system/carbon-charts](https://github.com/carbon-design-system/carbon-charts) | [ionix-ray/carbon-charts](https://github.com/ionix-ray/carbon-charts) | `main` | 1,055 | 220 | HTML | 2026-10-21 | ok | Apache-2.0 |  |
| [belt-sh/cli](https://github.com/belt-sh/cli) | [ionix-ray/cli](https://github.com/ionix-ray/cli) | `main` | 7 | 0 | Shell | 2026-09-27 | ok | MIT |  |
| [experientiallabs/experiential-enterprise](https://github.com/experientiallabs/experiential-enterprise) | [ionix-ray/experiential-enterprise](https://github.com/ionix-ray/experiential-enterprise) | `main` | 0 | 0 | - | - | deleted | unknown | upstream deleted |
| [experientiallabs/experiential](https://github.com/experientiallabs/experiential) | [ionix-ray/experiential](https://github.com/ionix-ray/experiential) | `main` | 10,172 | 240 | Python | 2026-10-10 | ok | Apache-2.0 |  |
| [Portkey-AI/models](https://github.com/Portkey-AI/models) | [ionix-ray/models](https://github.com/ionix-ray/models) | `main` | 143 | 47 | JavaScript | 2026-10-22 | ok | MIT |  |
| [hassan-algo/open-sesame](https://github.com/hassan-algo/open-sesame) | [ionix-ray/open-sesame](https://github.com/ionix-ray/open-sesame) | `main` | 19 | 3 | HTML | 2026-10-21 | ok | OTHER |  |
| [Portkey-AI/openapi](https://github.com/Portkey-AI/openapi) | [ionix-ray/openapi](https://github.com/ionix-ray/openapi) | `master` | 7 | 7 | - | 2026-10-19 | ok | MIT |  |
| [pixie-io/pixie](https://github.com/pixie-io/pixie) | [ionix-ray/pixie](https://github.com/ionix-ray/pixie) | `main` | 6,550 | 507 | C++ | 2026-10-19 | ok | Apache-2.0 |  |
| [Qiskit/qiskit](https://github.com/Qiskit/qiskit) | [ionix-ray/qiskit](https://github.com/ionix-ray/qiskit) | `main` | 7,915 | 3,089 | Python | 2026-10-22 | ok | Apache-2.0 |  |
| [morluto/rea](https://github.com/morluto/rea) | [ionix-ray/rea](https://github.com/ionix-ray/rea) | `main` | 359,211 | 90,163 | TypeScript | 2026-10-22 | ok | MIT |  |
| [kyegomez/swarms](https://github.com/kyegomez/swarms) | [ionix-ray/swarms](https://github.com/ionix-ray/swarms) | `master` | 7,285 | 1,047 | Python | 2026-10-21 | ok | Apache-2.0 |  |
| [vtmocanu/uzi](https://github.com/vtmocanu/uzi) | [ionix-ray/uzi](https://github.com/ionix-ray/uzi) | `main` | 92 | 4 | Go | 2026-10-22 | ok | MIT |  |
| [gfx-rs/wgpu](https://github.com/gfx-rs/wgpu) | [ionix-ray/wgpu](https://github.com/ionix-ray/wgpu) | `trunk` | 18,346 | 1,557 | Rust | 2026-10-22 | ok | Apache-2.0 |  |

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
