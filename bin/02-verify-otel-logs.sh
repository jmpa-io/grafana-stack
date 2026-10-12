#!/usr/bin/env bash
set -euo pipefail

# Confirms a real downstream consumer's own log output is actually landing
# in Loki, AND that those log lines carry trace/log correlation fields
# (traceid/spanid) — not just that raw lines show up.
#
# Current reference consumer: harrier-backend (harrier's frontend has no
# OTLP log exporter by design, so only the backend is checked here). See
# bin/lib/otel-verify-common.sh to point this at a different consumer.
#
# See 01-verify-otel-trace-link.sh for a check that a SPECIFIC trace id's
# logs land; this one is about the pipeline landing logs at all, independent
# of any one trace.
#
# Prerequisites (not started by this script):
#   - this stack running (make run) — Tempo :3200, Loki :3100, Prometheus :9090
#   - harrier-otel-sidecar running
#   - harrier-frontend-otel running (harrier's make docker-up-otel / --profile otel)
#   - harrier-backend-app-1 running, any OTEL_ENABLED state — this script
#     temporarily enables it if needed and restores the original state on exit
#
# Usage: make verify-otel-logs  (or: bin/02-verify-otel-logs.sh, from repo root)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

FINDINGS_PATH="/api/v1/harrier-svc/data/consolidated-findings?page=0&limit=5"
SCRATCH="$(mktemp "${TMPDIR:-/tmp}/verify-otel-logs.XXXXXX")"
LOKI_RESULT_FILE="$SCRATCH.loki.json"
trap 'rm -f "$SCRATCH" "$LOKI_RESULT_FILE"' EXIT

echo "== checking prerequisites =="
check_otel_prereqs

echo "== ensuring the backend's OTel javaagent is attached (restoring current state on exit) =="
ensure_backend_otel_enabled
trap 'restore_backend_otel; rm -f "$SCRATCH" "$LOKI_RESULT_FILE"' EXIT

echo "== generating backend traffic for Loki to capture =="
for _ in 1 2 3; do
  curl -s -o /dev/null "$FRONTEND_URL$FINDINGS_PATH" || true
done

echo "== check 1/2: Loki has recent harrier-svc log lines =="
check_loki_has_logs() {
  local start end
  start=$(($(date -u +%s) - 120))
  end=$(date -u +%s)
  curl -sf -G "$LOKI_URL/loki/api/v1/query_range" \
    --data-urlencode 'query={service_name="harrier-svc"}' \
    --data-urlencode "start=${start}000000000" \
    --data-urlencode "end=${end}000000000" \
    --data-urlencode 'limit=20' > "$LOKI_RESULT_FILE"
  jq -e '.data.result | length > 0' "$LOKI_RESULT_FILE" >/dev/null
}
if poll 8 5 check_loki_has_logs; then
  echo "PASS: harrier-svc log lines are landing in Loki (last 2 minutes)"
else
  fail "no harrier-svc log lines found in Loki in the last 2 minutes — is OTel logging wired up on the backend?"
fi

echo "== check 2/2: those log lines carry trace/log correlation fields (traceid) =="
if jq -e '[.data.result[].values[][1]] | any(test("traceid"))' "$LOKI_RESULT_FILE" >/dev/null; then
  echo "PASS: found log line(s) with a traceid field — trace/log correlation is wired, not just raw lines landing"
  jq -r '[.data.result[].values[][1]] | map(select(test("traceid")))[0]' "$LOKI_RESULT_FILE"
else
  fail "harrier-svc log lines are landing but none contain a 'traceid' field — trace/log correlation is broken"
fi

echo
echo "ALL CHECKS PASSED: harrier-svc logs are landing in Loki with trace correlation"
