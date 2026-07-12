# Conflict-free registry design

## The problem

`.github/synced-repos.yml` was a single file that held two kinds of data with two
different owners writing to it:

- **Declared intent** — `upstream`, `private`, `branch`, `paused`, `pause_reason`.
  Human/PR-owned, changes rarely.
- **Observed upstream state** — stars, forks, description, topics, languages,
  license, timestamps. A *cache* of what GitHub reports. Bot-owned, changes daily.

Two writers editing the same `repos:` array on the same branch produced merge
conflicts:

1. The daily `sync-status` cron rewrote the whole array (many `yq -i` writes,
   full re-serialization) and committed to `main`. Any open registration PR was
   cut from an older `main`, so it collided on merge.
2. Every registration appended to the tail of the list, so two open registration
   PRs collided at the same spot.
3. `register-repo.sh` also captured license metadata into the PR branch — the
   exact fields the bot rewrites on `main`.

## The fix — separate source-of-truth from derived state, one file per record

```
tracker/
  config.json                     version + defaults        (PR-owned)
  registry/<owner>__<repo>.json   INTENT, one per mirror     (PR-owned)
  metadata/<owner>__<repo>.json   OBSERVED state, one each   (bot-owned)
  schemas/*.schema.json
repo-status.json                  generated read-model       (bot-owned)
```

Write ownership is **disjoint**:

| Path                    | Written by            | When                    |
|-------------------------|-----------------------|-------------------------|
| `tracker/registry/*`    | humans / register PRs | registration, pause     |
| `tracker/metadata/*`    | sync workflow (bot)   | daily + on PR merge     |
| `repo-status.json`, `README.md`, `REPO_STATUS.md` | sync workflow (bot) | daily + on PR merge |

Because the register (PR) path writes **only** `tracker/registry/*` and the sync
(bot) path writes **only** `tracker/metadata/*` + generated files, a daily metadata
commit and an open registration PR can never touch the same bytes.

Because each mirror is its **own file**, registration is a pure *add* of a new
path — even two simultaneously open registration PRs cannot conflict.

## What is still guaranteed

- **Single source of truth is preserved.** `repo-status.json` joins intent +
  metadata into one object; `index.html` and the dashboards read it. Nothing about
  "one place to look" changes for consumers.
- **Upstream changes are still tracked in git as JSON.** The bot still pulls stars,
  license, etc. every run — into `tracker/metadata/*`, committed to `main`.
- **Registration still goes through a PR** (single-file add).
- **Deletions don't fight the PR path.** `cleanup-deleted.sh` marks
  `upstream_state: deleted` in the bot-owned metadata rather than deleting the
  human-owned intent file; removing a mirror is a deliberate PR that deletes the
  intent file.

## Determinism

All JSON the bot writes goes through `write_json_stable` (jq `-S`, 2-space indent,
trailing newline) or Python `sort_keys`. Only changed values change lines — no
whole-file re-serialization churn.

## Proof

`tests/test-no-conflict.sh` builds a throwaway git repo and runs real three-way
merges:

- **CONTROL** (old design: one shared list file, two writers) → must conflict.
  This proves the harness can actually detect a conflict.
- **CASE 1** two concurrent registrations (each adds a new file) → clean.
- **CASE 2** a registration PR vs a bot metadata refresh on main → clean.
- **CASE 3** a human pause edit vs a bot metadata refresh → clean.

Run the whole offline suite with `bash tests/run-all.sh`.
