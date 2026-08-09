#!/usr/bin/env bash
# render-readme.sh
# Regenerates README.md from the unified read-model repo-status.json.
# Idempotent: same input -> same output. Bot-owned output.
# Env: JSON_OUT (default repo-status.json), OUT (default README.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

OUT="${OUT:-README.md}"
[[ -f "$JSON_OUT" ]] || { echo "::error::$JSON_OUT missing — run generate-json.sh first"; exit 1; }

python3 - "$JSON_OUT" "$OUT" << 'PY'
import json, sys
from datetime import datetime, timezone

data = json.load(open(sys.argv[1]))
out_path = sys.argv[2]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

repos = data.get("repos", [])
summary = data.get("summary", {})
defaults = data.get("defaults", {})
count = len(repos)

def status_of(r):
    if r.get("paused"): return "paused"
    if r.get("upstream_state") == "deleted": return "deleted"
    if r.get("upstream_archived") or r.get("upstream_state") == "archived": return "archived"
    return r.get("last_synced_status") or "(pending)"

healthy = sum(1 for r in repos if not r.get("paused") and status_of(r) in ("ok", "(pending)", "skipped"))
paused  = sum(1 for r in repos if r.get("paused"))
diverged = sum(1 for r in repos if r.get("last_synced_status") == "diverged")
failed   = sum(1 for r in repos if r.get("last_synced_status") == "failed")
archived = summary.get("archived_count", 0)

L = []
L.append("# github-private-mirror-ops")
L.append("")
L.append(f"_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: `{now}`._")
L.append("")
L.append("## Summary")
L.append("")
L.append(f"- Mirrors registered: **{count}**")
L.append(f"- Status: healthy **{healthy}** · paused **{paused}** · diverged **{diverged}** · failed **{failed}** · archived **{archived}**")
L.append(f"- Total upstream stars: **{summary.get('total_stars',0):,}** · forks: **{summary.get('total_forks',0):,}**")
L.append(f"- Daily sync: `{defaults.get('schedule','')}` UTC")
L.append(f"- Strategy: `{defaults.get('strategy','')}`")
L.append("")
L.append("## Mirrors")
L.append("")
if count == 0:
    L.append("_No mirrors registered yet. Run **Actions → New Private Fork** to add one._")
    L.append("")
else:
    L.append("| Upstream | Private | Branch | Stars | Forks | Lang | Last Push | Status | License | Notes |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for r in repos:
        up, pr, br = r.get("upstream",""), r.get("private",""), r.get("branch","")
        stars, forks = r.get("stargazers_count",0), r.get("forks_count",0)
        lang = r.get("language") or "-"
        pushed = (r.get("upstream_pushed_at") or "-")[:10]
        st = status_of(r)
        lic = r.get("license_current_spdx") or "unknown"
        notes = []
        if r.get("paused"): notes.append(f"paused: {r.get('pause_reason') or 'unknown'}")
        if r.get("upstream_state") == "deleted": notes.append("upstream deleted")
        elif r.get("upstream_archived") or r.get("upstream_state") == "archived": notes.append("upstream archived")
        hist = len(r.get("license_history", []))
        if hist: notes.append(f"license changed {hist}x")
        L.append(f"| [{up}](https://github.com/{up}) | [{pr}](https://github.com/{pr}) | `{br}` | {stars:,} | {forks:,} | {lang} | {pushed} | {st} | {lic} | {'; '.join(notes)} |")
    L.append("")
    # License change log
    changes = []
    for r in repos:
        for h in r.get("license_history", []):
            changes.append((h.get("date",""), r.get("upstream",""), h.get("from_spdx",""), h.get("to_spdx",""), h.get("upstream_sha","")))
    L.append("## License Change Log")
    L.append("")
    if not changes:
        L.append("_No license changes detected so far._")
    else:
        L.append("| Date | Repo | From | To | Upstream SHA |")
        L.append("|---|---|---|---|---|")
        for d, rp, f, t, s in sorted(changes, reverse=True):
            L.append(f"| {d} | [{rp}](https://github.com/{rp}) | {f} | {t} | `{s or '?'}` |")
    L.append("")

L.append("## Architecture")
L.append("")
L.append("- **Intent** (what to mirror) lives in `tracker/registry/<owner>__<repo>.json` — one file per mirror, human/PR-owned. Registration adds a new file, so it never conflicts.")
L.append("- **Metadata** (observed upstream state) lives in `tracker/metadata/<owner>__<repo>.json` — bot-owned, written only by workflows.")
L.append("- **Read-model** `repo-status.json` joins both and is what `index.html` and this dashboard render.")
L.append("- Schemas: `tracker/schemas/`. Config (version + defaults): `tracker/config.json`.")
L.append("")
L.append("## Workflows")
L.append("")
L.append("- **New Private Fork** — `Actions → New Private Fork` (manual, input-driven). Pick where the private mirror lands via the **owner dropdown** (config-driven in `tracker/owners.json`); opens a registration PR that adds one intent file.")
L.append("- **Bulk Import** — import many repos at once (manual, comma-separated list).")
L.append("- **Sync Mirrors** — daily cron (fast-forward only). Pushes upstream changes into each private mirror; divergence opens an issue + auto-pause PR.")
L.append("- **Sync Status Dashboard** — auto-runs on PR merge + daily cron. Writes only metadata + generated files.")
L.append("")
L.append("## Operating model")
L.append("")
L.append("- Strategy: **fast-forward only**. Divergence triggers an issue + auto-pause; never force-pushes.")
L.append("- Owners: `tracker/owners.json` maps every dropdown owner to its PAT secret + environment. `tests/test-owners.sh` fails on dropdown/config drift.")
L.append("- Secrets: per-owner PATs stored under the names in `tracker/owners.json`. Never accepted via dispatch inputs.")
L.append("- Registry: intent files under `tracker/registry/` are the source of truth for what is mirrored. Metadata is a cache of upstream reality, refreshed by the bot.")
L.append("- For a rich interactive dashboard, open `index.html` locally (reads `repo-status.json`).")

open(out_path, "w").write("\n".join(L) + "\n")
print(f"rendered {out_path} ({count} repo(s))")
PY
