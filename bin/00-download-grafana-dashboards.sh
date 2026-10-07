#!/usr/bin/env bash
# Downloads official Grafana community dashboards into grafana/dashboards/<folder>/.
# Falls back gracefully if offline.
set -euo pipefail

die() { echo "$1" >&2; exit "${2:-1}"; }

# check deps.
deps=(curl)
missing=()
for dep in "${deps[@]}"; do
  hash "$dep" 2>/dev/null || missing+=("$dep")
done
[[ ${#missing[@]} -ne 0 ]] && die "missing deps: ${missing[*]}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# ── Infrastructure ────────────────────────────────────────────────────────────
download 1860 "infrastructure" "node-exporter-full"

# ── Kubernetes ────────────────────────────────────────────────────────────────
download 15661 "kubernetes" "k8s-cluster"
download 13332 "kubernetes" "k8s-pods"
download 19268 "kubernetes" "argocd"

# ── Observability stack internals ─────────────────────────────────────────────
download 3662 "observability" "prometheus"
download 13407 "observability" "loki"
download 17573 "observability" "tempo"
download 15983 "observability" "otel-collector"

# ── Media ─────────────────────────────────────────────────────────────────────
download 12103 "media" "arr-suite"

echo "Done."
