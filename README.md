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
make stop
```

## Other useful commands

```bash
make logs    # tail logs from all services
make status  # show running container status
make restart # stop + start
```

## Services

Once running, the following are available:

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
