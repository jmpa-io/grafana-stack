#!/usr/bin/env bash
# download.sh — downloads official Grafana community dashboards.
# Run once at deploy time. Falls back gracefully if offline.
#
# Usage: bash grafana/dashboards/download.sh <dest_dir>
#
# Dashboards are downloaded from grafana.com/api/dashboards/{id}/revisions/latest/download
# and saved as JSON files in the destination directory under subfolders.

set -uo pipefail

DEST="${1:-/etc/grafana/provisioning/dashboards}"

log() { echo "[grafana-stack/dashboards] $1"; }

download() {
  local id="$1"
  local folder="$2"
  local name="$3"
  local dest="${DEST}/${folder}"
  mkdir -p "${dest}"
  if curl -sf --connect-timeout 5 --max-time 30 \
    "https://grafana.com/api/dashboards/${id}/revisions/latest/download" \
    -o "${dest}/${name}.json" 2>/dev/null; then
    log "  OK  ${folder}/${name} (ID: ${id})"
  else
    log "  SKIP ${folder}/${name} (ID: ${id}) — offline or unavailable"
    rm -f "${dest}/${name}.json"
  fi
}

log "Downloading official Grafana community dashboards..."

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

log "Done."
