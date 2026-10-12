#!/usr/bin/env bash
set -euo pipefail

# Confirms a single distributed trace actually ties a frontend and backend
# together end-to-end through THIS stack: the backend's server span must be
# a CHILD of the frontend's client span under the SAME trace id (not just
# two unrelated signals that happen to share an id), and that same trace id
# must show up unprompted in Loki's log output. The same check against
# Prometheus exemplars is best-effort — exemplar storage only retains a few
# samples per bucket per scrape, so it can legitimately miss this specific
# trace under concurrent traffic; that case is a WARN, not a FAIL.
#
# Current reference consumer: harrier (frontend) + harrier-backend. See
# bin/lib/otel-verify-common.sh to point this at a different consumer.
#
# For broader (non-trace-specific) checks that logs/metrics are landing at
# all, see 02-verify-otel-logs.sh and 03-verify-otel-metrics.sh.
#
# Prerequisites (not started by this script):
#   - this stack running (make run) — Tempo :3200, Loki :3100, Prometheus :9090
#   - harrier-otel-sidecar running
#   - harrier-frontend-otel running (harrier's make docker-up-otel / --profile otel)
#   - harrier-backend-app-1 running, any OTEL_ENABLED state — this script
#     temporarily enables it if needed and restores the original state on exit
#
# Usage: make verify-otel-trace  (or: bin/01-verify-otel-trace-link.sh, from repo root)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib/otel-verify-common.sh
source "$SCRIPT_DIR/lib/otel-verify-common.sh"
require_repo_root

FINDINGS_PATH="/api/v1/harrier-svc/data/consolidated-findings?page=0&limit=5"
SCRATCH="$(mktemp "${TMPDIR:-/tmp}/verify-otel-trace-link.XXXXXX")"
trap 'rm -f "$SCRATCH"' EXIT

echo "== checking prerequisites =="
check_otel_prereqs

echo "== ensuring the backend's OTel javaagent is attached (restoring current state on exit) =="
ensure_backend_otel_enabled
trap 'restore_backend_otel; rm -f "$SCRATCH"' EXIT

echo "== emitting one trace: frontend span (parent) -> real backend call carrying it as a W3C traceparent =="
TRACE_ID=$(python3 -c "import secrets; print(secrets.token_hex(16))")
PARENT_SPAN=$(python3 -c "import secrets; print(secrets.token_hex(8))")
NOW_NS=$(($(date +%s)*1000000000))

curl -sf -X POST "$FRONTEND_URL/harrier/harrier-web/otlp/v1/traces" \
  -H "Content-Type: application/json" \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"harrier-web\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"verify-otel-trace-link\"},\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$PARENT_SPAN\",\"name\":\"GET $FINDINGS_PATH\",\"kind\":3,\"startTimeUnixNano\":\"$NOW_NS\",\"endTimeUnixNano\":\"$NOW_NS\"}]}]}]}" \
  -o /dev/null || fail "could not POST the frontend span through nginx's /otlp/ proxy"

# The findings endpoint has a known page-index bug and returns 500 — that's
# fine, it still traces and logs on error, which is exactly what this test needs.
curl -s -o /dev/null -H "traceparent: 00-$TRACE_ID-$PARENT_SPAN-01" "$FRONTEND_URL$FINDINGS_PATH" || true

echo "trace id under test: $TRACE_ID"

echo "== check 1/3: Tempo — harrier-svc's server span is a CHILD of harrier-web's client span =="
check_tempo() {
  python3 - "$TRACE_ID" "$TEMPO_URL" <<'PYEOF'
import json, sys, urllib.request
trace_id, tempo_url = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(f"{tempo_url}/api/traces/{trace_id}") as r:
    data = json.load(r)
frontend_span_ids, backend_parent_ids = set(), set()
for b in data.get("batches", []):
    svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", []) if a["key"] == "service.name"), None)
    for ss in b.get("scopeSpans", []):
        for sp in ss.get("spans", []):
            if svc == "harrier-web":
                frontend_span_ids.add(sp["spanId"])
            elif svc == "harrier-svc" and sp.get("parentSpanId"):
                backend_parent_ids.add(sp["parentSpanId"])
if not frontend_span_ids:
    sys.exit("no harrier-web span found in this trace")
if not backend_parent_ids:
    sys.exit("no harrier-svc span found in this trace")
shared = frontend_span_ids & backend_parent_ids
if not shared:
    sys.exit(f"harrier-svc spans exist but none are parented by the harrier-web span (frontend={frontend_span_ids}, backend parents={backend_parent_ids})")
print(f"harrier-svc span is parented by harrier-web span {shared}")
PYEOF
}
if poll 8 5 check_tempo; then
  cat "$SCRATCH"
  echo "PASS: harrier-svc's span is a child of harrier-web's span under trace $TRACE_ID"
else
  cat "$SCRATCH" >&2
  fail "trace linkage not found in Tempo after 40s"
fi

echo "== check 2/3: Loki — backend's own log output contains this exact trace id =="
check_loki() {
  local start end result
  start=$(($(date -u +%s) - 300))
  end=$(date -u +%s)
  result=$(curl -sf -G "$LOKI_URL/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"harrier-svc\"} |= \"$TRACE_ID\"" \
    --data-urlencode "start=${start}000000000" \
    --data-urlencode "end=${end}000000000" \
    --data-urlencode 'limit=5')
  echo "$result" | jq -e '.data.result | length > 0' >/dev/null
}
if poll 8 5 check_loki; then
  echo "PASS: found backend log line(s) containing trace id $TRACE_ID"
else
  fail "trace id $TRACE_ID not found in Loki's harrier-svc logs after 40s"
fi

echo "== check 3/3 (best-effort): Prometheus — exemplar on the real latency metric carries this trace id =="
check_prom() {
  local start end result
  start=$(($(date -u +%s) - 300))
  end=$(date -u +%s)
  result=$(curl -sf -G "$PROM_URL/api/v1/query_exemplars" \
    --data-urlencode 'query=http_server_request_duration_seconds_bucket{exported_job="harrier-svc"}' \
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
