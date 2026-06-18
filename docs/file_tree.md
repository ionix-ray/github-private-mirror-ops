# File Tree

```
github-private-mirror-ops/
├── .github/
│   ├── scripts/
│   │   ├── capture-license.sh       # Captures upstream license SPDX (legacy wrapper)
│   │   ├── cleanup-deleted.sh       # Removes deleted upstream/private repos from registry
│   │   ├── generate-json.sh         # Generates repo-status.json from synced-repos.yml
│   │   ├── generate-md.sh           # Generates REPO_STATUS.md from repo-status.json
│   │   ├── mirror-clone-push.sh     # Core mirror logic: clone public repo -> create private -> push
│   │   ├── refresh-metadata.sh      # Enriches registry with live GitHub API metadata
│   │   ├── register-repo.sh         # Adds new entry to synced-repos.yml and opens PR
│   │   ├── render-readme.sh         # Generates README.md summary from registry
│   │   ├── validate-owner.sh        # Validates PAT scopes and owner permissions
│   │   └── validate-registry.sh     # Offline + live semantic validation of registry
│   ├── workflows/
│   │   ├── lint.yml                 # CI lint gate: shellcheck, actionlint, schema checks
│   │   ├── new-private-fork.yml     # Manual workflow: create new private fork
│   │   └── sync-status.yml          # Auto-runs on PR merge + cron: cleanup + metadata + dashboards
│   ├── CODEOWNERS
│   ├── registry.schema.json         # JSON Schema for synced-repos.yml
│   └── synced-repos.yml             # Source of truth for all mirrors
├── docs/
│   └── file_tree.md                 # This file
├── index.html                       # Self-contained interactive dashboard (local viewing)
├── LICENSE
├── README.md                        # Auto-generated repo overview
├── repo-status.json                 # Auto-generated JSON source of truth for dashboards
└── REPO_STATUS.md                   # Auto-generated rich markdown dashboard
```
