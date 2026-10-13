#!/usr/bin/env bash
set -euo pipefail

# Confirms the OTLP metrics push path is actually working for EVERY service
# listed in SERVICES — not just that one happens to be emitting while
# another silently stopped.
#
# This script knows nothing about any specific consumer — the caller must
# have already generated real traffic for each service before invoking this.
# See harrier's scripts/verify-otel.sh for a worked example of a consumer
# driving this.
#
# See 01-verify-otel-trace-link.sh for a check that a SPECIFIC trace id has
# a Prometheus exemplar; this one is about the pipeline landing metrics at
# all, independent of any one trace.
#
# Required env vars:
#   SERVICES - space-separated list of exported_job values to check for
#
# Usage: SERVICES="harrier-svc nginx" make verify-otel-metrics
#    or: SERVICES="harrier-svc nginx" bin/03-verify-otel-metrics.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

require_env SERVICES verify-otel-metrics

SCRATCH="$(mktemp "${TMPDIR:-/tmp}/verify-otel-metrics.XXXXXX")"
TARGET_INFO_FILE="$SCRATCH.target_info.json"
trap 'rm -f "$SCRATCH" "$TARGET_INFO_FILE"' EXIT

echo "== checking prerequisites =="
check_otel_prereqs

echo "== check: Prometheus target_info has entries for exported_job in: $SERVICES =="
check_target_jobs() {
  curl -sf "$PROM_URL/api/v1/query?query=target_info" > "$TARGET_INFO_FILE"
  for svc in $SERVICES; do
    jq -e --arg s "$svc" '[.data.result[].metric.exported_job] | contains([$s])' "$TARGET_INFO_FILE" >/dev/null
  done
}
if poll 8 5 check_target_jobs; then
  echo "PASS: Prometheus has target_info for all of: $SERVICES"
  jq -c '[.data.result[].metric | {exported_job, job}]' "$TARGET_INFO_FILE"
else
  echo "current target_info exported_job values:" >&2
  jq -c '[.data.result[].metric.exported_job]' "$TARGET_INFO_FILE" >&2 2>/dev/null || true
  fail "Prometheus is missing target_info for at least one of: $SERVICES — OTLP metrics push path is broken for that service"
fi

echo
echo "ALL CHECKS PASSED: all of [$SERVICES] are pushing metrics via OTLP into Prometheus"
