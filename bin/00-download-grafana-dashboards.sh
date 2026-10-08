#!/usr/bin/env bash
# Downloads official Grafana community dashboards into grafana/dashboards/<folder>/.
# Falls back gracefully if offline.
set -euo pipefail

die() { echo "$1" >&2; exit "${2:-1}"; }

# check deps.
deps=(curl git)
missing=()
for dep in "${deps[@]}"; do
  hash "$dep" 2>/dev/null || missing+=("$dep")
done
[[ ${#missing[@]} -ne 0 ]] && die "missing deps: ${missing[*]}"

# must be run from the repo root.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
[[ "$PWD" == "$REPO_ROOT" ]] || die "must be run from repo root ($REPO_ROOT)"

DEST="${1:-$REPO_ROOT/grafana/dashboards}"

download() {
  local id="$1" folder="$2" name="$3"
  local dest="${DEST}/${folder}"
  mkdir -p "$dest"
  if curl -sf --connect-timeout 5 --max-time 30 \
    "https://grafana.com/api/dashboards/${id}/revisions/latest/download" \
    -o "${dest}/${name}.json" 2>/dev/null; then
    echo "[OK]   ${folder}/${name} (ID: ${id})"
  else
    echo "[SKIP] ${folder}/${name} (ID: ${id}) — offline or unavailable"
    rm -f "${dest}/${name}.json"
  fi
}

# id folder name
dashboards=(
  "1860 infrastructure node-exporter-full"
  "15661 kubernetes k8s-cluster"
  "13332 kubernetes k8s-pods"
  "19268 kubernetes argocd"
  "3662 observability prometheus"
  "13407 observability loki"
  "17573 observability tempo"
  "15983 observability otel-collector"
  "12103 media arr-suite"
)

for entry in "${dashboards[@]}"; do
  read -r id folder name <<< "$entry"
  download "$id" "$folder" "$name"
done

echo "Done."
