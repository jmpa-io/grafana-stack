
# Default PROJECT, if not given by another Makefile.
ifndef PROJECT
PROJECT=grafana-stack
endif

# Override the default dependency list — this is a Docker Compose project, not Go.
DEPENDENCIES := docker

LOKI_PLUGIN_IMAGE  := grafana/loki-docker-driver:3.0.0

# Targets.

download-dashboards: # Downloads official Grafana community dashboards to grafana/dashboards/.
download-dashboards:
	bash bin/00-download-grafana-dashboards.sh grafana/dashboards

install-loki-plugin: # Installs the Loki Docker logging plugin if not already present.
install-loki-plugin:
	@docker plugin inspect loki >/dev/null 2>&1 || \
		docker plugin install $(LOKI_PLUGIN_IMAGE) --alias loki --grant-all-permissions

run: ## ** Runs ALL docker-compose services locally (installs Loki plugin if needed).
run: install-loki-plugin
	docker compose up \
		--build \
		--force-recreate \
		--remove-orphans

PHONY += download-dashboards install-loki-plugin run

---: ## ---

# Includes the common Makefile.
# NOTE: this recursively goes back and finds the `.git` directory and assumes
# this is the root of the project. This could have issues when this assumtion
# is incorrect.
include $(shell while [[ ! -d .git ]]; do cd ..; done; pwd)/Makefile.common.mk
