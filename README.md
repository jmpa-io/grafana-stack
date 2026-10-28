<!-- markdownlint-disable MD041 MD010 -->
<p align="center">
    <img src="docs/logo.png">
</p>

## `grafana-stack`

```diff
+ 👀 An observability stack for monitoring all the other running services in this org.
+    Runs locally via Docker Compose. Intended to be deployed to a homelab via Ansible.
```

<a href="LICENSE" target="_blank"><img src="https://img.shields.io/github/license/jmpa-io/grafana-stack.svg" alt="GitHub License"></a>

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)

## Running locally

```bash
make run
```

This will:
1. Install the [Loki Docker logging plugin](https://grafana.com/docs/loki/latest/send-data/docker-driver/) if not already installed (required once per machine)
2. Start all services via `docker compose`

## Stopping

```bash
make stop    # stops the containers; your data is kept
make reset   # stops AND deletes all stored metrics, logs, traces and Grafana state
```

## Your data persists

Prometheus, Loki, Tempo and Grafana each use a named Docker volume (`prometheus-data`, `loki-data`, `tempo-data`, `grafana-data`). They survive `make stop`, `make restart` and `make run`. Only `make reset` (or `docker compose down --volumes`) deletes them. Prometheus keeps 30 days; Tempo keeps traces for 48 hours.

## Dashboards

```bash
make download-dashboards   # one-off: fetches the community dashboards into grafana/dashboards/<folder>/
```

The downloaded JSON is git-ignored. Until you run it, Grafana starts with no dashboards.

## Other useful commands

```bash
make logs    # tail logs from all services
make status  # show running container status
make restart # stop + start
```

## Services

Once running, the following are available. Every port is published on `127.0.0.1` only, because Grafana has anonymous Admin and no login, so nothing is reachable from your network:

| Service | URL | Purpose |
|:---|:---|:---|
| Grafana | http://localhost:3000 | Dashboards (anonymous admin, no login required) |
| Prometheus | http://localhost:9090 | Metrics storage + scraping |
| Loki | http://localhost:3100 | Log storage |
| Tempo | http://localhost:3200 | Trace storage |
| OTel Collector (gRPC) | localhost:4319 | Send traces, metrics, logs via OTLP/gRPC |
| OTel Collector (HTTP) | localhost:4320 | Send traces, metrics, logs via OTLP/HTTP |

## Sending data

Point any OpenTelemetry-instrumented app at the OTel Collector:

```bash
# gRPC (recommended)
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4319

# HTTP
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4320
```

All three signals (traces, metrics, logs) are accepted and forwarded to the appropriate backend.

Container logs from all services in the stack are automatically shipped to Loki via the Docker logging driver.

## Watching OTel data live

```bash
SERVICES="svc-a svc-b" make watch-otel
```

Continuously refreshing, color-coded terminal view of what's actually landing in Tempo/Loki/Prometheus right now, grouped per service. Observational only — it doesn't pass/fail anything.

```bash
# SERVICES is required; INTERVAL (seconds) is optional and defaults to 5
SERVICES="svc-a svc-b" INTERVAL=3 make watch-otel
```

## Verifying OTel data (pass/fail)

Generic checks against whatever is actually sending data into this stack right now. The caller supplies trace id / service names — these scripts know nothing about any specific consumer:

```bash
TRACE_ID=... PARENT_SERVICE=... CHILD_SERVICE=... make verify-otel-trace  # one trace ties two services together (Tempo + Loki + Prometheus exemplar)
SERVICE=... make verify-otel-logs                                         # SERVICE's logs are landing in Loki with trace correlation
SERVICES="svc-a svc-b" make verify-otel-metrics                           # every service in SERVICES is pushing metrics
```

See `.claude/skills/otel-pipeline-verify/SKILL.md` for the full reference, and `watch-otel`/`verify-otel-*` targets in the `Makefile` for exact invocation. A consumer repo owns generating real traffic and calling these with its own values.
