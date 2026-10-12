
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

# OTel pipeline verification (against a real downstream consumer — see bin/lib/otel-verify-common.sh)

verify-otel-trace: ## Prove one trace actually ties a consumer's frontend+backend together in Tempo/Loki/Prometheus.
verify-otel-trace:
	bin/01-verify-otel-trace-link.sh

verify-otel-logs: ## Prove a consumer's backend logs are landing in Loki with trace/log correlation fields.
verify-otel-logs:
	bin/02-verify-otel-logs.sh

verify-otel-metrics: ## Prove a consumer's frontend and backend are both pushing metrics via OTLP into Prometheus.
verify-otel-metrics:
	bin/03-verify-otel-metrics.sh

verify-otel: ## Run all three OTel pipeline checks against a real consumer: traces, logs, metrics.
verify-otel: verify-otel-trace verify-otel-logs verify-otel-metrics

PHONY += verify-otel-trace verify-otel-logs verify-otel-metrics verify-otel

---: ## ---

# Includes the common Makefile.
# NOTE: this recursively goes back and finds the `.git` directory and assumes
# this is the root of the project. This could have issues when this assumtion
# is incorrect.
include $(shell while [[ ! -d .git ]]; do cd ..; done; pwd)/Makefile.common.mk
