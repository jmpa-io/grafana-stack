---
name: otel-pipeline-verify
description: Stand up this stack (Tempo/Loki/Prometheus/Grafana + otel-collector) and verify a downstream consumer's traces/logs/metrics are actually landing and correlating — with live evidence, not just config inspection. Invoke with "/otel-pipeline-verify" or when asked to audit/verify this stack's OTel ingestion locally.
---

Verify end-to-end OTel ingestion in THIS stack for whatever consumer is calling it. This repo owns zero consumer-specific knowledge — no service names, no container names, no app URLs are hardcoded anywhere here. Every check takes the consumer's values (trace id, service names) as required env vars. Generating real traffic and knowing which of its own containers to toggle is the consumer's job — see "Working with a consumer repo" below.

## What's running here

- `tempo` — traces, ports 3200 (query API) / 4317+4318 (OTLP)
- `loki` — logs, port 3100
- `prometheus` — metrics, port 9090
- `grafana` — dashboards, port 3000
- `open-telemetry-collector` — this stack's own otel-collector, ports 4319/4320

## Steps

### 1. Check current state

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'grafana|tempo|loki|prometheus|open-telemetry'
```

### 2. Bring the stack up

```bash
cd ~/go/src/github.com/jmpa-io/grafana-stack && make run
```

Public images, no auth needed. `make status` / `make logs` / `make stop` / `make restart` are also available.

### 3. Automated checks (preferred — re-runnable, no manual curl)

Three independent scripts, shared reachability-check logic in `bin/lib/otel-verify-common.sh` (sourced, not standalone). Each only asserts against Tempo/Loki/Prometheus — nothing here starts a consumer's containers, generates its traffic, or toggles its instrumentation; a hard prerequisite failure in one of these almost always means the *consumer's* side wasn't primed first.

#### `make verify-otel-trace TRACE_ID=... PARENT_SERVICE=... CHILD_SERVICE=...` (`bin/01-verify-otel-trace-link.sh`)

Proves one SPECIFIC trace (already emitted by the consumer) ties two services together:

1. **Tempo**: `CHILD_SERVICE`'s server span is a *child* of `PARENT_SERVICE`'s client span under `TRACE_ID` (hard fail if not).
2. **Loki**: `TRACE_ID` appears in `CHILD_SERVICE`'s own log output (hard fail if not).
3. **Prometheus**: `TRACE_ID` appears as an exemplar on `http_server_request_duration_seconds_bucket{exported_job="$CHILD_SERVICE"}` (best-effort WARN, not a fail — exemplar storage only keeps a few samples per bucket per scrape, so a specific trace can legitimately get evicted under concurrent traffic).

#### `make verify-otel-logs SERVICE=...` (`bin/02-verify-otel-logs.sh`)

Proves logs are landing at all for `SERVICE` (not tied to one trace id): asserts Loki has recent `service_name="$SERVICE"` log lines (hard fail if not) AND that those lines carry a `traceid` field (hard fail if not — raw lines landing without correlation fields is still a failure, since the point is trace/log correlation, not just log shipping).

#### `make verify-otel-metrics SERVICES="svc-a svc-b ..."` (`bin/03-verify-otel-metrics.sh`)

Proves metrics are landing at all for EVERY service listed: asserts Prometheus's `target_info` has an entry for each `exported_job` value given (hard fail on any missing) — catches the case where one service silently stops pushing while another keeps working.

Each of the above requires real traffic to already have happened — none of these scripts generate traffic themselves. A consumer calls them *after* driving its own traffic.

### 4. Manual verification (fallback, if you need to eyeball raw data)

Traces:

```bash
curl -s "http://localhost:3200/api/traces/$TRACE_ID"
```

Logs:

```bash
curl -s -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name="<SERVICE>"}' \
  --data-urlencode "start=$(date -u -v-10M +%s 2>/dev/null || date -u -d '10 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  --data-urlencode 'limit=5'
```

Metrics:

```bash
curl -s "http://localhost:9090/api/v1/query?query=target_info" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
    print(r['metric'].get('exported_job'), r['metric'].get('job'))
"
```

## Working with a consumer repo

A consumer repo (one whose app sends telemetry here) owns:

- Bringing up its own app containers and this stack's otel-collector sidecar, if any.
- Toggling its own OTel instrumentation on/off for the duration of a test, and restoring it afterward.
- Generating real traffic — emitting a trace, hitting endpoints enough times for logs/metrics to show up.
- Calling the three `make verify-otel-*` targets above with its own service names and trace id, then reporting pass/fail.

See `harrier`'s `.claude/skills/otel-pipeline-check` skill and `scripts/verify-otel.sh` for a worked example of a consumer driving this stack end-to-end.

## Self-verification (don't just assert it works)

Claude has no camera and cannot take screenshots. "I confirmed X" in prose is not proof — it's a claim. Every check here must be independently re-runnable by the user, not taken on faith:

- **Always show the exact command alongside the result**, not a summary of what it showed.
- **Never use a healthcheck's own status as proof the thing it checks works**, if you just edited that healthcheck. Hit the real endpoint instead (`curl .../ready`, `curl .../-/healthy`).
- **For file-content fixes (Makefile, compose files), the proof is `git diff`**, not a description of what changed.
- **For anything with a UI, point the user at it directly**: Grafana Explore → Tempo/Loki/Prometheus datasources, `http://localhost:3000`.

## Report format

For each signal (trace linkage, logs, metrics) state pass/fail with the concrete evidence (trace ID, log line, metric series) and the exact command used — not "looks configured correctly" and not just the result with the command omitted. Prefer `make verify-otel-trace`/`verify-otel-logs`/`verify-otel-metrics` over manual curl sequences — it's the same evidence, automated and re-runnable.
