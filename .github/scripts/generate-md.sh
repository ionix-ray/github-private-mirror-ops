#!/usr/bin/env bash
# generate-md.sh
# Generates REPO_STATUS.md from repo-status.json.
# Rich markdown with tables, status badges, and opportunity insights.
# Env: JSON_OUT (default repo-status.json), MD_OUT (default REPO_STATUS.md)

set -euo pipefail

JSON_OUT="${JSON_OUT:-repo-status.json}"
MD_OUT="${MD_OUT:-REPO_STATUS.md}"

if [[ ! -f "$JSON_OUT" ]]; then
  echo "::error::JSON $JSON_OUT missing"
  exit 1
fi

python3 - "$JSON_OUT" "$MD_OUT" << 'PY'
import json, sys
from datetime import datetime, timezone

data = json.load(open(sys.argv[1]))
out_path = sys.argv[2]
now = datetime.now(timezone.utc)

repos = data.get("repos", [])
summary = data.get("summary", {})

lines = []
lines.append("# Mirror Registry Status Dashboard")
lines.append("")
lines.append(f"_Auto-generated private dashboard. Last updated: `{data.get('generated_at', now.isoformat())}`._")
lines.append("")

# --- Summary ---
lines.append("## Summary")
lines.append("")
lines.append(f"| Metric | Value |")
lines.append(f"|---|---|")
lines.append(f"| Total Mirrored Repos | **{summary.get('total_repos', 0)}** |")
lines.append(f"| Total Stars (upstream) | {summary.get('total_stars', 0):,} |")
lines.append(f"| Total Forks (upstream) | {summary.get('total_forks', 0):,} |")
lines.append(f"| Total Open Issues | {summary.get('total_open_issues', 0):,} |")
lines.append(f"| Archived Upstreams | {summary.get('archived_count', 0)} |")
lines.append(f"| Paused Mirrors | {summary.get('paused_count', 0)} |")
lines.append(f"| License Changes Detected | {summary.get('license_changes', 0)} |")
lines.append("")

# --- Language Breakdown ---
lang_totals = {}
for r in repos:
    for lang, bytes_val in r.get("languages", {}).items():
        lang_totals[lang] = lang_totals.get(lang, 0) + bytes_val

if lang_totals:
    lines.append("## Language Distribution")
    lines.append("")
    lines.append("| Language | Bytes | Share |")
    lines.append("|---|---|---|")
    total_bytes = sum(lang_totals.values())
    for lang, bytes_val in sorted(lang_totals.items(), key=lambda x: -x[1])[:15]:
        pct = bytes_val / total_bytes * 100 if total_bytes else 0
        bar = "█" * int(pct / 5)
        lines.append(f"| {lang} | {bytes_val:,} | {bar} {pct:.1f}% |")
    lines.append("")

# --- License Breakdown ---
licenses = {}
for r in repos:
    lic = r.get("license_current_spdx") or "Unknown"
    licenses[lic] = licenses.get(lic, 0) + 1

if licenses:
    lines.append("## License Distribution")
    lines.append("")
    lines.append("| License | Count |")
    lines.append("|---|---|")
    for lic, cnt in sorted(licenses.items(), key=lambda x: -x[1]):
        lines.append(f"| {lic} | {cnt} |")
    lines.append("")

# --- Repo Detail Table ---
lines.append("## Mirror Details")
lines.append("")
lines.append("| # | Status | Upstream | Private | Stars | Forks | Issues | Lang | Last Push | Health | Opportunity |")
lines.append("|---|--------|----------|---------|-------|-------|--------|------|-----------|--------|-------------|")

for idx, r in enumerate(repos, 1):
    up = r.get("upstream", "")
    pr = r.get("private", "")
    branch = r.get("branch", "")
    stars = r.get("stargazers_count", 0)
    forks = r.get("forks_count", 0)
    issues = r.get("open_issues_count", 0)
    lang = r.get("language") or "-"
    pushed = r.get("upstream_pushed_at", "")[:10] if r.get("upstream_pushed_at") else "-"
    paused = r.get("paused", False)
    archived = r.get("upstream_archived", False)
    comp = r.get("_computed", {})
    health = comp.get("health_score", 0)
    opp = comp.get("opportunity_flag", "")
    days = comp.get("days_since_push")

    status_emoji = "🟢"
    status_text = "active"
    if paused:
        status_emoji = "⏸️"
        status_text = "paused"
    elif archived:
        status_emoji = "📦"
        status_text = "archived"
    elif days is not None and days > 365:
        status_emoji = "🟡"
        status_text = "stale"

    health_bar = ""
    if health >= 80:
        health_bar = f"🟢 {health}"
    elif health >= 50:
        health_bar = f"🟡 {health}"
    else:
        health_bar = f"🔴 {health}"

    opp_text = opp or "-"

    lines.append(
        f"| {idx} | {status_emoji} {status_text} | "
        f"[{up}](https://github.com/{up}) | "
        f"[{pr}](https://github.com/{pr}) | "
        f"{stars:,} | {forks:,} | {issues:,} | "
        f"{lang} | {pushed} | {health_bar} | {opp_text} |"
    )

lines.append("")

# --- Opportunity Insights ---
opportunities = [(r.get("upstream", ""), r.get("_computed", {}).get("opportunity_flag", "")) for r in repos if r.get("_computed", {}).get("opportunity_flag")]
if opportunities:
    lines.append("## 🎯 Opportunity Insights")
    lines.append("")
    lines.append("| Repo | Insight |")
    lines.append("|---|---|")
    for up, opp in opportunities:
        lines.append(f"| [{up}](https://github.com/{up}) | {opp} |")
    lines.append("")

# --- License Change Log ---
license_changes = []
for r in repos:
    for h in r.get("license_history", []):
        license_changes.append((h.get("date", ""), r.get("upstream", ""), h.get("from_spdx", ""), h.get("to_spdx", "")))

if license_changes:
    lines.append("## License Change Log")
    lines.append("")
    lines.append("| Date | Repo | From | To |")
    lines.append("|---|---|---|---|")
    for date, up, frm, to in sorted(license_changes, reverse=True):
        lines.append(f"| {date} | [{up}](https://github.com/{up}) | {frm} | {to} |")
    lines.append("")

# --- Technical Notes ---
lines.append("## Technical Notes")
lines.append("")
lines.append("- **Health Score**: Composite metric (0-100) based on stars, forks, recency, issues, discussions, and license clarity.")
lines.append("- **Opportunity Flag**: Business/technical insight derived from star/fork ratio, issue velocity, template status, and community engagement.")
lines.append("- **Stale**: No push in >365 days. May indicate abandoned but popular projects worth reviving.")
lines.append("- **Archived**: Upstream has been archived by owner. Consider pausing sync.")
lines.append("- This file is auto-generated. Do not edit manually.")
lines.append("")

with open(out_path, "w") as f:
    f.write("\n".join(lines))
print(f"generated {out_path}: {len(repos)} repo(s)")
PY
