#!/usr/bin/env bash
set -euo pipefail

# Confirms the OTLP metrics push path is actually working for BOTH sides of
# a real downstream consumer — backend (via the javaagent) and frontend
# (via its nginx otel module) — not just that one side happens to be
# emitting while the other silently stopped.
#
# Current reference consumer: app (nginx) + app-backend. See
# bin/lib/otel-verify-common.sh to point this at a different consumer.
#
# See 01-verify-otel-trace-link.sh for a check that a SPECIFIC trace id has
# a Prometheus exemplar; this one is about the pipeline landing metrics at
# all, independent of any one trace.
#
# Prerequisites (not started by this script):
#   - this stack running (make run) — Tempo :3200, Loki :3100, Prometheus :9090
#   - app-otel-sidecar running
#   - app-frontend-otel running (app's make docker-up-otel / --profile otel)
#   - app-backend-app-1 running, any OTEL_ENABLED state — this script
#     temporarily enables it if needed and restores the original state on exit
#
# Usage: make verify-otel-metrics  (or: bin/03-verify-otel-metrics.sh, from repo root)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

SCRATCH="$(mktemp "${TMPDIR:-/tmp}/verify-otel-metrics.XXXXXX")"
TARGET_INFO_FILE="$SCRATCH.target_info.json"
trap 'rm -f "$SCRATCH" "$TARGET_INFO_FILE"' EXIT

echo "== checking prerequisites =="
check_otel_prereqs

echo "== ensuring the backend's OTel javaagent is attached (restoring current state on exit) =="
ensure_backend_otel_enabled
trap 'restore_backend_otel; rm -f "$SCRATCH" "$TARGET_INFO_FILE"' EXIT

echo "== generating traffic through both the backend and the nginx-proxied frontend =="
curl -s -o /dev/null "$FRONTEND_URL/app/app-web/" || true
for _ in 1 2 3; do
  curl -s -o /dev/null "$FRONTEND_URL/api/v1/app-svc/actuator/health" || true
done

echo "== check: Prometheus target_info has entries for both exported_job=app-svc and exported_job=nginx =="
check_target_jobs() {
  curl -sf "$PROM_URL/api/v1/query?query=target_info" > "$TARGET_INFO_FILE"
  jq -e '[.data.result[].metric.exported_job] | contains(["app-svc"])' "$TARGET_INFO_FILE" >/dev/null
  jq -e '[.data.result[].metric.exported_job] | contains(["nginx"])' "$TARGET_INFO_FILE" >/dev/null
}
if poll 8 5 check_target_jobs; then
  echo "PASS: Prometheus has target_info for both exported_job=app-svc and exported_job=nginx"
  jq -c '[.data.result[].metric | {exported_job, job}]' "$TARGET_INFO_FILE"
else
  echo "current target_info exported_job values:" >&2
  jq -c '[.data.result[].metric.exported_job]' "$TARGET_INFO_FILE" >&2 2>/dev/null || true
  fail "Prometheus is missing target_info for app-svc and/or nginx — OTLP metrics push path is broken for at least one service"
fi

echo
echo "ALL CHECKS PASSED: both app-svc and nginx are pushing metrics via OTLP into Prometheus"
