
# Default PROJECT, if not given by another Makefile.
ifndef PROJECT
PROJECT=grafana-stack
endif

# Override the default dependency list — this is a Docker Compose project, not Go.
DEPENDENCIES := docker

LOKI_PLUGIN_ALIAS  := loki
LOKI_PLUGIN_IMAGE  := grafana/loki-docker-driver:3.0.0

# Targets.

download-dashboards: # Downloads official Grafana community dashboards to grafana/dashboards/.
download-dashboards:
	bash grafana/dashboards/download.sh grafana/dashboards

PHONY += download-dashboards

---: ## ---

run: ## ** Runs ALL docker-compose services locally (installs Loki plugin if needed).
run:
	@if ! docker plugin ls | grep -q "$(LOKI_PLUGIN_ALIAS)"; then \
		echo "Installing Loki Docker logging plugin..."; \
		docker plugin install $(LOKI_PLUGIN_IMAGE) --alias $(LOKI_PLUGIN_ALIAS) --grant-all-permissions; \
	else \
		echo "Loki Docker logging plugin already installed."; \
	fi
	docker compose up \
		--build \
		--force-recreate \
		--remove-orphans

PHONY += run

---: ## ---

# Includes the common Makefile.
# NOTE: this recursively goes back and finds the `.git` directory and assumes
# this is the root of the project. This could have issues when this assumtion
# is incorrect.
include $(shell while [[ ! -d .git ]]; do cd ..; done; pwd)/Makefile.common.mk

