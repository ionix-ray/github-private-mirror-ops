#!/usr/bin/env bash
# generate-json.sh
# Joins intent (tracker/registry/*.json) + metadata (tracker/metadata/*.json) into
# the unified read-model repo-status.json — the single source of truth for readers
# (index.html, REPO_STATUS.md, README.md). Adds computed fields.
# Bot-owned output; regenerated every sync run.
#
# Env: TRACKER_DIR, JSON_OUT (default repo-status.json)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

[[ -d "$REG_DIR" ]] || { echo "::error::registry dir $REG_DIR missing"; exit 1; }

python3 - "$REG_DIR" "$META_DIR" "$CONFIG_FILE" "$JSON_OUT" << 'PY'
import json, sys, os, glob
from datetime import datetime, timezone

reg_dir, meta_dir, config_file, out_path = sys.argv[1:5]
now = datetime.now(timezone.utc)

config = {}
if os.path.exists(config_file):
    config = json.load(open(config_file))

def key(full): return full.replace("/", "__")

repos = []
for rf in sorted(glob.glob(os.path.join(reg_dir, "*.json"))):
    intent = json.load(open(rf))
    k = key(intent["private"])
    mf = os.path.join(meta_dir, f"{k}.json")
    meta = json.load(open(mf)) if os.path.exists(mf) else {}

    # Merge: intent wins on its own fields; metadata supplies observed state.
    r = dict(meta)
    r.update(intent)

    pushed_str = r.get("upstream_pushed_at", "")
    days_since_push = None
    if pushed_str:
        try:
            pushed = datetime.fromisoformat(pushed_str.replace("Z", "+00:00"))
            days_since_push = (now - pushed).days
        except Exception:
            pass

    score = 0
    if r.get("stargazers_count", 0) > 0:
        score += min(r["stargazers_count"] // 10, 20)
    if r.get("forks_count", 0) > 0:
        score += min(r["forks_count"] // 5, 15)
    if days_since_push is not None and days_since_push < 30:
        score += 20
    elif days_since_push is not None and days_since_push < 90:
        score += 10
    if 0 < r.get("open_issues_count", 0) < 50:
        score += 10
    if r.get("has_discussions"):
        score += 10
    if r.get("license_current_spdx") and r["license_current_spdx"] != "NOASSERTION":
        score += 10
    if r.get("upstream_archived") or r.get("upstream_state") == "archived":
        score = max(score - 40, 0)
    score = min(score, 100)

    opp = ""
    stars = r.get("stargazers_count", 0)
    forks = r.get("forks_count", 0)
    if stars > 1000 and forks < stars // 10:
        opp = "High demand, low competition"
    elif stars > 500 and r.get("open_issues_count", 0) > stars // 20:
        opp = "Active community, many open issues"
    elif r.get("is_template"):
        opp = "Template repo — reusable pattern"
    elif r.get("has_discussions") and stars > 100:
        opp = "Strong community engagement"
    elif days_since_push is not None and days_since_push > 365 and stars > 500:
        opp = "Popular but stale — potential revival"

    r["_computed"] = {
        "health_score": score,
        "opportunity_flag": opp,
        "days_since_push": days_since_push,
        "generated_at": now.isoformat(),
    }
    repos.append(r)

output = {
    "generated_at": now.isoformat(),
    "version": config.get("version", 1),
    "defaults": config.get("defaults", {}),
    "summary": {
        "total_repos": len(repos),
        "total_stars": sum(r.get("stargazers_count", 0) for r in repos),
        "total_forks": sum(r.get("forks_count", 0) for r in repos),
        "total_open_issues": sum(r.get("open_issues_count", 0) for r in repos),
        "archived_count": sum(1 for r in repos if r.get("upstream_archived") or r.get("upstream_state") == "archived"),
        "deleted_count": sum(1 for r in repos if r.get("upstream_state") == "deleted"),
        "paused_count": sum(1 for r in repos if r.get("paused")),
        "license_changes": sum(len(r.get("license_history", [])) for r in repos),
    },
    "repos": repos,
}

with open(out_path, "w") as f:
    json.dump(output, f, indent=2, default=str)
    f.write("\n")
print(f"generated {out_path}: {len(repos)} repo(s)")
PY
