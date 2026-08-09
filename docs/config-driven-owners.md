# Config-driven owners (where private mirrors land)

Every workflow that creates or syncs a private mirror lets you pick the target
owner from a **dropdown**. That dropdown is not free-form — it is the single
source of truth in `tracker/owners.json`, and every option maps to the PAT that
has admin access to that owner, so the mirror **lands in the owner you picked**.

## The file

`tracker/owners.json`:

```json
{
  "$schema": "./schemas/owners.schema.json",
  "owners": [
    { "owner": "cyfen-code",
      "secret_name": "GH_SYNC_PAT_CYFEN_CODE",
      "environment": "GH_SYNC_PAT_SAMIRPARHI_DEV" },
    { "owner": "ionix-ray",
      "secret_name": "GH_SYNC_PAT_IONIX_RAY",
      "environment": "GH_SYNC_PAT_IONIX_RAY" }
  ]
}
```

| Field         | Meaning                                                                    |
|---------------|----------------------------------------------------------------------------|
| `owner`       | The GitHub account/org the private mirror is created under.                |
| `secret_name` | Actions **secret** holding that owner's fine-grained PAT (org/user admin). |
| `environment` | Actions **environment** that secret lives in (repo environments or org).   |

## How a pick resolves

`.github/scripts/resolve-owner.sh` (used by `new-private-fork.yml`,
`bulk-import.yml`, `sync-mirrors.yml`, `sync-status.yml`) reads `owners.json`
and emits:

- `secret_name` — so the job can do `secrets[<secret_name>]`
- `environment` — so the job's `environment:` key matches where that secret lives

The PAT is then masked and used only where it is needed: API calls and git
access to the **private** repo. The ops-repo checkout/commit uses the default
`GITHUB_TOKEN`.

## Adding a new owner (e.g. a second personal account)

1. Create the Actions secret (e.g. `GH_SYNC_PAT_ALICE`) + environment for the
   new owner.
2. Add an entry to `tracker/owners.json` following the schema.
3. Add the same value as an `option` under the `target_owner` input in each
   workflow that has the dropdown (`new-private-fork.yml`, `bulk-import.yml`,
   `sync-mirrors.yml`).

## Drift protection

`tests/test-owners.sh` (run by `bash tests/run-all.sh` and the `lint.yml`
workflow) fails if any dropdown option is **not** present in `owners.json`, or
if `owners.json` fails its schema. A dropdown choice can therefore never exist
that would try to land a mirror under an owner with no PAT configured.

```sh
bash tests/test-owners.sh   # PASS = dropdowns and config are in sync
```
