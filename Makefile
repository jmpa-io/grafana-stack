
# Default PROJECT, if not given by another Makefile.
ifndef PROJECT
PROJECT=grafana-stack
endif

# Override the default dependency list — this is a Docker Compose project, not Go.
DEPENDENCIES := docker

LOKI_PLUGIN_ALIAS  := loki
LOKI_PLUGIN_IMAGE  := grafana/loki-docker-driver:3.0.0

# Targets.

install-loki-plugin: ## Installs the Loki Docker logging plugin (required once per machine).
install-loki-plugin:
	@if ! docker plugin ls | grep -q "$(LOKI_PLUGIN_ALIAS)"; then \
		echo "Installing Loki Docker logging plugin..."; \
		docker plugin install $(LOKI_PLUGIN_IMAGE) --alias $(LOKI_PLUGIN_ALIAS) --grant-all-permissions; \
	else \
		echo "Loki Docker logging plugin already installed."; \
	fi

PHONY += install-loki-plugin

download-dashboards: ## Downloads official Grafana community dashboards to grafana/dashboards/.
download-dashboards:
	bash grafana/dashboards/download.sh grafana/dashboards

PHONY += download-dashboards

---: ## ---

run: ## ** Runs ALL docker-compose services locally (installs Loki plugin if needed).
run: install-loki-plugin
	docker compose up \
		--build \
		--force-recreate \
		--remove-orphans

PHONY += run

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

# Includes the common Makefile.
# NOTE: this recursively goes back and finds the `.git` directory and assumes
# this is the root of the project. This could have issues when this assumtion
# is incorrect.
include $(shell while [[ ! -d .git ]]; do cd ..; done; pwd)/Makefile.common.mk

