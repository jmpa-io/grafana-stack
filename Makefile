
# Default PROJECT, if not given by another Makefile.
ifndef PROJECT
PROJECT=grafana-stack
endif

# Override the default dependency list — this is a Docker Compose project, not Go.
DEPENDENCIES := docker

LOKI_PLUGIN_ALIAS ?= loki
LOKI_PLUGIN_IMAGE ?= grafana/loki-docker-driver:3.0.0

# Targets.
download-dashboards: ## Downloads official Grafana community dashboards to grafana/dashboards/.
download-dashboards:
	bash bin/00-download-grafana-dashboards.sh grafana/dashboards

install-loki-plugin: ## Installs the Loki Docker logging plugin if not already present.
install-loki-plugin:
	@docker plugin inspect $(LOKI_PLUGIN_ALIAS) >/dev/null 2>&1 || \
		docker plugin install $(LOKI_PLUGIN_IMAGE) --alias $(LOKI_PLUGIN_ALIAS) --grant-all-permissions

run: ## ** Runs ALL docker-compose services locally (installs Loki plugin if needed).
run: install-loki-plugin
	docker compose up \
		--build \
		--force-recreate \
		--remove-orphans

PHONY += download-dashboards install-loki-plugin run

stop: ## Stops and removes ALL docker-compose services.
stop:
	docker compose down

PHONY += stop

restart: ## Restarts ALL docker-compose services.
restart: stop run

PHONY += restart

logs: ## Tails logs from ALL docker-compose services.
logs:
	docker compose logs -f

PHONY += logs

status: ## Shows the status of all docker-compose services.
status:
	docker compose ps

PHONY += status

---: ## ---

# OTel pipeline verification — generic checks against THIS stack's Tempo/
# Loki/Prometheus. These scripts know nothing about any specific consumer;
# the caller supplies trace id and service names (see bin/lib/otel-verify-common.sh).
# A consumer repo (e.g. harrier) owns generating real traffic and calling
# these with its own values — see harrier's scripts/verify-otel.sh.

verify-otel-trace: ## Prove one trace ties PARENT_SERVICE and CHILD_SERVICE together in Tempo/Loki/Prometheus. Required: TRACE_ID, PARENT_SERVICE, CHILD_SERVICE.
verify-otel-trace:
	TRACE_ID=$(TRACE_ID) PARENT_SERVICE=$(PARENT_SERVICE) CHILD_SERVICE=$(CHILD_SERVICE) bin/01-verify-otel-trace-link.sh

verify-otel-logs: ## Prove SERVICE's logs are landing in Loki with trace/log correlation fields. Required: SERVICE.
verify-otel-logs:
	SERVICE=$(SERVICE) bin/02-verify-otel-logs.sh

verify-otel-metrics: ## Prove every service in SERVICES is pushing metrics via OTLP into Prometheus. Required: SERVICES (space-separated).
verify-otel-metrics:
	SERVICES="$(SERVICES)" bin/03-verify-otel-metrics.sh

watch-otel: ## Live, color-coded terminal view of traces/logs/metrics landing per service, refreshing every INTERVAL seconds. Optional: SERVICES (space-separated, default: harrier-web harrier-svc nginx), INTERVAL (default: 5).
watch-otel:
	bin/watch-otel.sh

PHONY += verify-otel-trace verify-otel-logs verify-otel-metrics watch-otel

---: ## ---

# Includes the common Makefile.
# NOTE: this recursively goes back and finds the `.git` directory and assumes
# this is the root of the project. This could have issues when this assumtion
# is incorrect.
include $(shell while [[ ! -d .git ]]; do cd ..; done; pwd)/Makefile.common.mk
