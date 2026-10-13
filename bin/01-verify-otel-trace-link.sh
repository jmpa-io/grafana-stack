#!/usr/bin/env bash
set -euo pipefail

# Confirms a single distributed trace actually ties two services together
# end-to-end through THIS stack: CHILD_SERVICE's span must be a CHILD of
# PARENT_SERVICE's span under the SAME trace id (not just two unrelated
# signals that happen to share an id), and that same trace id must show up
# unprompted in Loki's log output. The same check against Prometheus
# exemplars is best-effort — exemplar storage only retains a few samples per
# bucket per scrape, so it can legitimately miss this specific trace under
# concurrent traffic; that case is a WARN, not a FAIL.
#
# This script knows nothing about any specific consumer — the caller must
# have already generated a real trace and pass its id and the two service
# names in. See harrier's scripts/verify-otel.sh for a worked example of a
# consumer driving this.
#
# For broader (non-trace-specific) checks that logs/metrics are landing at
# all, see 02-verify-otel-logs.sh and 03-verify-otel-metrics.sh.
#
# Required env vars:
#   TRACE_ID        - hex trace id already emitted into this stack
#   PARENT_SERVICE  - service.name expected on the parent (client) span
#   CHILD_SERVICE   - service.name expected on the child (server) span
#
# Usage: TRACE_ID=... PARENT_SERVICE=... CHILD_SERVICE=... make verify-otel-trace
#    or: TRACE_ID=... PARENT_SERVICE=... CHILD_SERVICE=... bin/01-verify-otel-trace-link.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

require_env TRACE_ID verify-otel-trace
require_env PARENT_SERVICE verify-otel-trace
require_env CHILD_SERVICE verify-otel-trace

SCRATCH="$(mktemp "${TMPDIR:-/tmp}/verify-otel-trace-link.XXXXXX")"
trap 'rm -f "$SCRATCH"' EXIT

echo "== checking prerequisites =="
check_otel_prereqs

echo "trace id under test: $TRACE_ID (parent=$PARENT_SERVICE, child=$CHILD_SERVICE)"

echo "== check 1/3: Tempo — $CHILD_SERVICE's server span is a CHILD of $PARENT_SERVICE's client span =="
check_tempo() {
  python3 - "$TRACE_ID" "$TEMPO_URL" "$PARENT_SERVICE" "$CHILD_SERVICE" <<'PYEOF'
import json, sys, urllib.request
trace_id, tempo_url, parent_service, child_service = sys.argv[1:5]
with urllib.request.urlopen(f"{tempo_url}/api/traces/{trace_id}") as r:
    data = json.load(r)
parent_span_ids, child_parent_ids = set(), set()
for b in data.get("batches", []):
    svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", []) if a["key"] == "service.name"), None)
    for ss in b.get("scopeSpans", []):
        for sp in ss.get("spans", []):
            if svc == parent_service:
                parent_span_ids.add(sp["spanId"])
            elif svc == child_service and sp.get("parentSpanId"):
                child_parent_ids.add(sp["parentSpanId"])
if not parent_span_ids:
    sys.exit(f"no {parent_service} span found in this trace")
if not child_parent_ids:
    sys.exit(f"no {child_service} span found in this trace")
shared = parent_span_ids & child_parent_ids
if not shared:
    sys.exit(f"{child_service} spans exist but none are parented by the {parent_service} span (parent={parent_span_ids}, child parents={child_parent_ids})")
print(f"{child_service} span is parented by {parent_service} span {shared}")
PYEOF
}
if poll 8 5 check_tempo; then
  cat "$SCRATCH"
  echo "PASS: $CHILD_SERVICE's span is a child of $PARENT_SERVICE's span under trace $TRACE_ID"
else
  cat "$SCRATCH" >&2
  fail "trace linkage not found in Tempo after 40s"
fi

echo "== check 2/3: Loki — $CHILD_SERVICE's own log output contains this exact trace id =="
check_loki() {
  local start end result
  start=$(($(date -u +%s) - 300))
  end=$(date -u +%s)
  result=$(curl -sf -G "$LOKI_URL/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"$CHILD_SERVICE\"} |= \"$TRACE_ID\"" \
    --data-urlencode "start=${start}000000000" \
    --data-urlencode "end=${end}000000000" \
    --data-urlencode 'limit=5')
  echo "$result" | jq -e '.data.result | length > 0' >/dev/null
}
if poll 8 5 check_loki; then
  echo "PASS: found $CHILD_SERVICE log line(s) containing trace id $TRACE_ID"
else
  fail "trace id $TRACE_ID not found in Loki's $CHILD_SERVICE logs after 40s"
fi

echo "== check 3/3 (best-effort): Prometheus — exemplar on the real latency metric carries this trace id =="
check_prom() {
  local start end result
  start=$(($(date -u +%s) - 300))
  end=$(date -u +%s)
  result=$(curl -sf -G "$PROM_URL/api/v1/query_exemplars" \
    --data-urlencode "query=http_server_request_duration_seconds_bucket{exported_job=\"$CHILD_SERVICE\"}" \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}")
  echo "$result" | jq -e --arg t "$TRACE_ID" '.data[].exemplars[]? | select(.labels.trace_id == $t)' >/dev/null
}
if poll 10 6 check_prom; then
  echo "PASS: found Prometheus exemplar with trace_id $TRACE_ID"
else
  echo "WARN: no Prometheus exemplar found for trace_id $TRACE_ID within 60s."
  echo "      Exemplar storage only keeps a few samples per bucket per scrape interval,"
  echo "      so a specific trace can be evicted under concurrent traffic — not a hard failure."
fi

echo
echo "ALL REQUIRED CHECKS PASSED for trace $TRACE_ID (Tempo + Loki; Prometheus best-effort)"
