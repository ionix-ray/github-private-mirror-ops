#!/usr/bin/env bash
# render-readme.sh
# Regenerates README.md from .github/synced-repos.yml.
# Idempotent: same input -> same output (no spurious diffs).

set -euo pipefail

REG=".github/synced-repos.yml"
OUT="README.md"

now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
count=$(yq -r '.repos | length' "$REG")
healthy=$(yq -r '[.repos[] | select(.paused == false and (.last_synced_status == "ok" or .last_synced_status == "" or .last_synced_status == "skipped"))] | length' "$REG")
paused=$( yq -r '[.repos[] | select(.paused == true)] | length' "$REG")
diverged=$(yq -r '[.repos[] | select(.last_synced_status == "diverged")] | length' "$REG")
failed=$(yq -r '[.repos[] | select(.last_synced_status == "failed")] | length' "$REG")

{
  echo "# github-private-mirror-ops"
  echo
  echo "_Live state dashboard. Auto-generated — do not hand-edit. Last refreshed: \`$now\`._"
  echo
  echo "## Summary"
  echo
  echo "- Mirrors registered: **$count**"
  echo "- Status: healthy **$healthy** · paused **$paused** · diverged **$diverged** · failed **$failed**"
  echo "- Daily sync: \`$(yq -r '.defaults.schedule' "$REG")\` UTC"
  echo "- Strategy: \`$(yq -r '.defaults.strategy' "$REG")\`"
  echo

  if [[ "$count" == "0" ]]; then
    echo "## Mirrors"
    echo
    echo "_No mirrors registered yet. Run **Actions → New Private Fork** to add one._"
    echo
  else
    echo "## Mirrors"
    echo
    echo "| Upstream | Private | Branch | Last Sync (UTC) | Status | License | Notes |"
    echo "|---|---|---|---|---|---|---|"
    for i in $(seq 0 $((count - 1))); do
      up=$(yq -r ".repos[$i].upstream" "$REG")
      pr=$(yq -r ".repos[$i].private"  "$REG")
      br=$(yq -r ".repos[$i].branch"   "$REG")
      ls=$(yq -r ".repos[$i].last_synced_at // \"never\"" "$REG")
      st=$(yq -r ".repos[$i].last_synced_status // \"(pending)\"" "$REG")
      lic=$(yq -r ".repos[$i].license_current_spdx // \"unknown\"" "$REG")
      paused=$(yq -r ".repos[$i].paused" "$REG")
      notes=""
      if [[ "$paused" == "true" ]]; then
        reason=$(yq -r ".repos[$i].pause_reason // \"\"" "$REG")
        notes="paused: ${reason:-unknown}"
        st="paused"
      fi
      hist_len=$(yq -r ".repos[$i].license_history | length" "$REG")
      if (( hist_len > 0 )); then
        notes="${notes:+$notes; }license changed ${hist_len}x"
      fi
      echo "| [$up](https://github.com/$up) | [$pr](https://github.com/$pr) | \`$br\` | $ls | $st | $lic | $notes |"
    done
    echo

    # license change log (flat, most recent first)
    echo "## License Change Log"
    echo
    rows=$(yq -r '
      [.repos[]
        | . as $r
        | (.license_history // [])
        | .[]
        | {date:.date, repo:$r.upstream, from:.from_spdx, to:.to_spdx, sha:.upstream_sha}]
      | sort_by(.date) | reverse | .[]
      | [.date, .repo, .from, .to, .sha] | @tsv
    ' "$REG" || true)
    if [[ -z "$rows" ]]; then
      echo "_No license changes detected so far._"
    else
      echo "| Date | Repo | From | To | Upstream SHA |"
      echo "|---|---|---|---|---|"
      printf '%s\n' "$rows" | while IFS=$'\t' read -r d r f t s; do
        echo "| $d | [$r](https://github.com/$r) | $f | $t | \`${s:-?}\` |"
      done
    fi
    echo
  fi

  echo "## Workflows"
  echo
  echo "- **New Private Fork** — \`Actions → New Private Fork\` (manual, input-driven)"
  echo "- **Sync Mirrors** — daily 06:00 UTC (Phase 2, coming)"
  echo "- **Migrate Public Forks** — bulk one-shot (Phase 3, coming)"
  echo
  echo "## Operating model"
  echo
  echo "- Strategy: **fast-forward only**. Divergence triggers an issue + auto-pause; never force-pushes."
  echo "- Secrets: per-owner classic PATs stored as \`GH_SYNC_PAT_<OWNER>\`. Never accepted via dispatch inputs."
  echo "- Registry: this dashboard is rendered from \`.github/synced-repos.yml\`. That file is the source of truth."
} > "$OUT"

echo "rendered $OUT ($count repo(s))"
