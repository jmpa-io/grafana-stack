#!/usr/bin/env bash
set -euo pipefail

# Confirms a service's own log output is actually landing in Loki, AND that
# those log lines carry trace/log correlation fields (traceid/spanid) — not
# just that raw lines show up.
#
# This script knows nothing about any specific consumer — the caller must
# have already generated real traffic for SERVICE before invoking this. See
# harrier's scripts/verify-otel.sh for a worked example of a consumer
# driving this.
#
# See 01-verify-otel-trace-link.sh for a check that a SPECIFIC trace id's
# logs land; this one is about the pipeline landing logs at all, independent
# of any one trace.
#
# Required env vars:
#   SERVICE - the service_name label to check in Loki
#
# Usage: SERVICE=... make verify-otel-logs
#    or: SERVICE=... bin/02-verify-otel-logs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

require_env SERVICE verify-otel-logs

SCRATCH="$(mktemp "${TMPDIR:-/tmp}/verify-otel-logs.XXXXXX")"
LOKI_RESULT_FILE="$SCRATCH.loki.json"
trap 'rm -f "$SCRATCH" "$LOKI_RESULT_FILE"' EXIT

echo "== checking prerequisites =="
check_otel_prereqs

echo "== check 1/2: Loki has recent $SERVICE log lines =="
check_loki_has_logs() {
  local start end
  start=$(($(date -u +%s) - 120))
  end=$(date -u +%s)
  curl -sf -G "$LOKI_URL/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"$SERVICE\"}" \
    --data-urlencode "start=${start}000000000" \
    --data-urlencode "end=${end}000000000" \
    --data-urlencode 'limit=20' > "$LOKI_RESULT_FILE"
  jq -e '.data.result | length > 0' "$LOKI_RESULT_FILE" >/dev/null
}
if poll 8 5 check_loki_has_logs; then
  echo "PASS: $SERVICE log lines are landing in Loki (last 2 minutes)"
else
  fail "no $SERVICE log lines found in Loki in the last 2 minutes — is OTel logging wired up for this service?"
fi

echo "== check 2/2: those log lines carry trace/log correlation fields (traceid) =="
if jq -e '[.data.result[].values[][1]] | any(test("traceid"))' "$LOKI_RESULT_FILE" >/dev/null; then
  echo "PASS: found log line(s) with a traceid field — trace/log correlation is wired, not just raw lines landing"
  jq -r '[.data.result[].values[][1]] | map(select(test("traceid")))[0]' "$LOKI_RESULT_FILE"
else
  fail "$SERVICE log lines are landing but none contain a 'traceid' field — trace/log correlation is broken"
fi

echo
echo "ALL CHECKS PASSED: $SERVICE logs are landing in Loki with trace correlation"
