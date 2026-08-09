# File Tree

```
github-private-mirror-ops/
├── .github/
│   ├── scripts/
│   │   ├── bulk-import.sh
│   │   ├── capture-license.sh
│   │   ├── cleanup-deleted.sh
│   │   ├── commit-bot-changes.sh
│   │   ├── generate-json.sh
│   │   ├── generate-md.sh
│   │   ├── guard-ownership.sh
│   │   ├── lib-gh.sh
│   │   ├── lib-tracker.sh
│   │   ├── mirror-clone-push.sh
│   │   ├── refresh-metadata.sh
│   │   ├── register-repo.sh
│   │   ├── render-readme.sh
│   │   ├── resolve-owner.sh
│   │   ├── sync-mirror.sh
│   │   ├── sync-mirrors.sh
│   │   ├── validate-owner.sh
│   │   └── validate-registry.sh
│   └── workflows/
│       ├── bulk-import.yml
│       ├── lint.yml
│       ├── new-private-fork.yml
│       ├── sync-mirrors.yml
│       └── sync-status.yml
├── docs/
│   ├── config-driven-owners.md  [docs]
│   ├── conflict-free-registry.md  [docs]
│   └── file_tree.md  [docs]
├── tests/
│   ├── fixtures/
│   │   ├── metadata/
│   │   │   ├── bad-enum-state.json  [config]
│   │   │   ├── bad-extra-property.json  [config]
│   │   │   ├── bad-license-history.json  [config]
│   │   │   ├── bad-negative-int.json  [config]
│   │   │   ├── valid-full.json  [config]
│   │   │   └── valid-minimal.json  [config]
│   │   └── registry/
│   │       ├── bad-empty-branch.json  [config]
│   │       ├── bad-extra-property.json  [config]
│   │       ├── bad-missing-required.json  [config]
│   │       ├── bad-pattern-upstream.json  [config]
│   │       ├── bad-type-paused.json  [config]
│   │       ├── valid-full.json  [config]
│   │       └── valid-minimal.json  [config]
│   ├── golden/
│   ├── run-all.sh
│   ├── run-schema-tests.sh
│   ├── test-lib-gh.sh
│   ├── test-no-conflict.sh
│   ├── test-ownership.sh
│   └── test-owners.sh
├── tracker/
│   ├── metadata/
│   │   ├── ionix-ray__carbon-charts.json  [config]
│   │   ├── ionix-ray__cli.json  [config]
│   │   ├── ionix-ray__PiRanha.json  [config]
│   │   ├── ionix-ray__pixie.json  [config]
│   │   ├── ionix-ray__qiskit.json  [config]
│   │   └── ionix-ray__wgpu.json  [config]
│   ├── owners.json  [config]
│   ├── registry/
│   │   ├── ionix-ray__carbon-charts.json  [config]
│   │   ├── ionix-ray__cli.json  [config]
│   │   ├── ionix-ray__PiRanha.json  [config]
│   │   ├── ionix-ray__pixie.json  [config]
│   │   ├── ionix-ray__qiskit.json  [config]
│   │   └── ionix-ray__wgpu.json  [config]
│   ├── schemas/
│   │   ├── config.schema.json  [config]
│   │   ├── metadata-record.schema.json  [config]
│   │   ├── owners.schema.json  [config]
│   │   └── registry-record.schema.json  [config]
│   └── config.json  [config]
├── .gitignore
├── CODEOWNERS
├── index.html
├── LICENSE
├── README.md
├── REPO_STATUS.md
└── repo-status.json  [config]
```
