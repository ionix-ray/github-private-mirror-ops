#!/usr/bin/env bash
# generate-json.sh
# Converts .github/synced-repos.yml into repo-status.json (single source of truth).
# Adds computed fields: health_score, opportunity_flag, days_since_push.
# Env: REG (default .github/synced-repos.yml), JSON_OUT (default repo-status.json)

set -euo pipefail

REG="${REG:-.github/synced-repos.yml}"
JSON_OUT="${JSON_OUT:-repo-status.json}"

if [[ ! -f "$REG" ]]; then
  echo "::error::registry $REG missing"
  exit 1
fi

python3 - "$REG" "$JSON_OUT" << 'PY'
import yaml, json, sys
from datetime import datetime, timezone

reg = yaml.safe_load(open(sys.argv[1]))
out_path = sys.argv[2]

now = datetime.now(timezone.utc)
repos = []

for r in reg.get("repos", []):
    # Compute days since last push
    pushed_str = r.get("upstream_pushed_at", "")
    days_since_push = None
    if pushed_str:
        try:
            pushed = datetime.fromisoformat(pushed_str.replace("Z", "+00:00"))
            days_since_push = (now - pushed).days
        except Exception:
            pass

    # Compute health score (0-100)
    score = 0
    if r.get("stargazers_count", 0) > 0:
        score += min(r["stargazers_count"] // 10, 20)
    if r.get("forks_count", 0) > 0:
        score += min(r["forks_count"] // 5, 15)
    if days_since_push is not None and days_since_push < 30:
        score += 20
    elif days_since_push is not None and days_since_push < 90:
        score += 10
    if r.get("open_issues_count", 0) > 0 and r.get("open_issues_count", 0) < 50:
        score += 10
    if r.get("has_discussions"):
        score += 10
    if r.get("license_current_spdx") and r["license_current_spdx"] != "NOASSERTION":
        score += 10
    if r.get("upstream_archived"):
        score = max(score - 40, 0)
    score = min(score, 100)

    # Opportunity flag: high stars + low forks = niche opportunity
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

    entry = dict(r)
    entry["_computed"] = {
        "health_score": score,
        "opportunity_flag": opp,
        "days_since_push": days_since_push,
        "generated_at": now.isoformat(),
    }
    repos.append(entry)

output = {
    "generated_at": now.isoformat(),
    "version": reg.get("version", 1),
    "defaults": reg.get("defaults", {}),
    "summary": {
        "total_repos": len(repos),
        "total_stars": sum(r.get("stargazers_count", 0) for r in repos),
        "total_forks": sum(r.get("forks_count", 0) for r in repos),
        "total_open_issues": sum(r.get("open_issues_count", 0) for r in repos),
        "archived_count": sum(1 for r in repos if r.get("upstream_archived")),
        "paused_count": sum(1 for r in repos if r.get("paused")),
        "license_changes": sum(len(r.get("license_history", [])) for r in repos),
    },
    "repos": repos,
}

with open(out_path, "w") as f:
    json.dump(output, f, indent=2, default=str)
print(f"generated {out_path}: {len(repos)} repo(s)")
PY
