# File Tree

```
github-private-mirror-ops/
├── .github/
│   ├── scripts/
│   │   ├── lib-tracker.sh          [shared paths + helpers]
│   │   ├── bulk-import.sh
│   │   ├── capture-license.sh      [bot: writes metadata only]
│   │   ├── cleanup-deleted.sh      [bot: marks metadata state]
│   │   ├── generate-json.sh        [bot: joins intent+metadata -> repo-status.json]
│   │   ├── generate-md.sh          [bot: repo-status.json -> REPO_STATUS.md]
│   │   ├── mirror-clone-push.sh
│   │   ├── refresh-metadata.sh     [bot: writes metadata only]
│   │   ├── register-repo.sh        [PR: writes one intent file only]
│   │   ├── render-readme.sh        [bot: repo-status.json -> README.md]
│   │   ├── validate-owner.sh
│   │   └── validate-registry.sh    [validates tracker/* against schemas]
│   └── workflows/
│       ├── bulk-import.yml
│       ├── lint.yml
│       ├── new-private-fork.yml
│       └── sync-status.yml
├── tracker/                         [all registry data lives here, as JSON]
│   ├── config.json                  [version + defaults; PR-owned]
│   ├── registry/                    [INTENT — one file per mirror; PR-owned]
│   │   └── <owner>__<repo>.json
│   ├── metadata/                    [OBSERVED state — one file per mirror; bot-owned]
│   │   └── <owner>__<repo>.json
│   └── schemas/
│       ├── config.schema.json
│       ├── registry-record.schema.json
│       └── metadata-record.schema.json
├── docs/
│   ├── file_tree.md
│   └── conflict-free-registry.md    [architecture + rationale]
├── tests/
│   ├── fixtures/
│   │   ├── registry/                [valid-*/bad-* intent records]
│   │   └── metadata/                [valid-*/bad-* metadata records]
│   ├── run-schema-tests.sh          [fixture validation]
│   ├── test-no-conflict.sh          [merge-conflict simulation]
│   └── run-all.sh                   [full offline suite]
├── CODEOWNERS                        [repo root]
├── index.html                       [reads repo-status.json]
├── LICENSE
├── README.md                        [generated]
├── REPO_STATUS.md                   [generated]
└── repo-status.json                 [generated read-model; bot-owned]
```
