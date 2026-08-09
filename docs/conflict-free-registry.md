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

## Production-grade single-writer guarantees

The conflict-free design rests on more than path convention. Three mechanisms
enforce it mechanically:

1. **One bot writer at a time.** `sync-status` and `sync-mirrors` — the two bots
   that both touch `tracker/metadata/*` + the read-model — share a **single
   concurrency group** (`bot-sync`). They can never run concurrently, so the
   read-modify-write in `refresh-metadata.sh` / `sync-mirror.sh` can never race
   a second writer. (Two bots *can* still conflict if their commits touch the
   same file — `tests/test-no-conflict.sh` CASE 4b proves they must — which is
   exactly why serialization is mandatory, not optional.)

2. **A single, conflict-tolerant commit primitive.** Every bot push goes through
   `.github/scripts/commit-bot-changes.sh`, which:
   - checks out the default branch first (so a leftover `pause/*` or `register/*`
     branch can never leak a registry edit into the main push — closes the
     pause-branch leak);
   - stages **only** bot-owned paths, never `tracker/registry/**`;
   - pushes with a **rebase-and-retry loop**, so an interleaved main write (a
     registration PR merged mid-run) is rebased onto, never force-pushed over.

3. **Ownership enforced in CI.** `guard-ownership.sh` (wired into `lint.yml`)
   **fails any PR that edits bot-owned files** (`tracker/metadata/*`,
   `repo-status.json`, `REPO_STATUS.md`, `README.md`). A human hand-edit of
   metadata can no longer silently race the bot.

The auto-pause path in `sync-mirror.sh` also honours the invariant: it never
writes `tracker/registry/*` on main — it opens a **PR** that sets
`paused: true`, and restores HEAD to the default branch so the edit cannot ride
the bot's own main push.

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
- **CASE 4a** a bot push rebased over a registration PR (different namespaces) → clean.
- **CASE 4b** two bots editing the same metadata file → **must conflict** (proves
  why the shared `bot-sync` concurrency group is required).

Run the whole offline suite with `bash tests/run-all.sh`.
