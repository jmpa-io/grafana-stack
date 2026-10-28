#!/usr/bin/env bash
set -uo pipefail

# Continuously refreshing, color-coded terminal view of what's actually
# landing in THIS stack right now — traces, logs, and metrics — grouped per
# service. This is an observational tool, not a pass/fail check: for that,
# use `make verify-otel-trace` / `verify-otel-logs` / `verify-otel-metrics`.
# Knows nothing about any specific consumer; SERVICES is just a list of
# service.name / exported_job values to watch.
#
# Required env vars:
#   SERVICES - space-separated service names to watch
# Optional env vars:
#   INTERVAL - refresh interval in seconds (default: 5)
#
# Usage: SERVICES="svc-a svc-b" make watch-otel
#    or: SERVICES="svc-a svc-b" INTERVAL=3 bin/watch-otel.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

require_env SERVICES watch-otel
INTERVAL="${INTERVAL:-5}"

echo "== checking prerequisites =="
SCRATCH="$(mktemp "${TMPDIR:-/tmp}/watch-otel.XXXXXX")"
trap 'rm -f "$SCRATCH"' EXIT
check_otel_prereqs

COLORS=(36 32 33 35 34 31)   # cyan green yellow magenta blue red, cycled by index
NOCLR=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

color_for() {
  local -i idx=0 i=0
  for s in $SERVICES; do
    [ "$s" = "$1" ] && { idx=$i; break; }
    i=$((i + 1))
  done
  echo $'\033['"${COLORS[$((idx % ${#COLORS[@]}))]}m"
}

fetch_traces() {
  local service="$1" start end
  start=$(($(date -u +%s) - INTERVAL * 4))
  end=$(date -u +%s)
  curl -sf -G "$TEMPO_URL/api/search" \
    --data-urlencode "tags=service.name=$service" \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$end" \
    --data-urlencode "limit=5" 2>/dev/null \
  | jq -r '.traces[]? | "\(.traceID[0:16])  \(.rootServiceName)  \(.rootTraceName // "-")  \((.durationMs // 0))ms"' 2>/dev/null
}

fetch_logs() {
  local service="$1" start end
  start=$(($(date -u +%s) - INTERVAL * 4))
  end=$(date -u +%s)
  curl -sf -G "$LOKI_URL/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"$service\"}" \
    --data-urlencode "start=${start}000000000" \
    --data-urlencode "end=${end}000000000" \
    --data-urlencode "limit=5" \
    --data-urlencode "direction=backward" 2>/dev/null \
  | jq -r '.data.result[]?.values[]? | .[1]' 2>/dev/null \
  | cut -c1-140
}

fetch_metric_freshness() {
  # Bare label-matcher query (no metric name) so this works for a service
  # that only exports one oddly-named counter (or none at all beyond
  # target_info) — not every service exports target_info itself.
  local service="$1" now result ts count
  result=$(curl -sf -G "$PROM_URL/api/v1/query" --data-urlencode "query={exported_job=\"$service\"}" 2>/dev/null)
  count=$(echo "$result" | jq -r '.data.result | length' 2>/dev/null)
  [ -z "$count" ] || [ "$count" = "0" ] && { echo "MISSING"; return; }
  ts=$(echo "$result" | jq -r '.data.result[0].value[0]? // empty' 2>/dev/null)
  now=$(date -u +%s)
  echo "$count series, last scrape $((now - ${ts%.*}))s ago"
}

render_once() {
  clear
  echo "${BOLD}otel pipeline watch${NOCLR}  ${DIM}(refresh every ${INTERVAL}s, Ctrl-C to stop — this is observational, not a pass/fail check)${NOCLR}"
  echo "${DIM}$(date -u +%FT%TZ)${NOCLR}"
  for service in $SERVICES; do
    local c
    c="$(color_for "$service")"
    echo
    echo "${c}${BOLD}== $service ==${NOCLR}"

    echo "${c}  metrics:${NOCLR} $(fetch_metric_freshness "$service")"

    echo "${c}  traces (last $((INTERVAL * 4))s):${NOCLR}"
    local traces
    traces="$(fetch_traces "$service")"
    if [ -z "$traces" ]; then
      echo "    ${DIM}(none)${NOCLR}"
    else
      echo "$traces" | sed 's/^/    /'
    fi

    echo "${c}  logs (last $((INTERVAL * 4))s):${NOCLR}"
    local logs
    logs="$(fetch_logs "$service")"
    if [ -z "$logs" ]; then
      echo "    ${DIM}(none)${NOCLR}"
    else
      echo "$logs" | sed 's/^/    /'
    fi
  done
}

while true; do
  render_once
  sleep "$INTERVAL"
done
