# shellcheck shell=bash
# Shared by bin/*-verify-otel-*.sh — stack reachability checks and a
# retry-with-delay helper. Not standalone; sourced, not executed.
#
# These scripts verify that THIS stack is actually receiving and correlating
# telemetry — trace linkage, log correlation, metrics push — from whatever
# consumer calls them. They take no consumer-specific knowledge (no service
# names, no container names, no app URLs): every signal a check needs about
# the consumer under test (trace id, service names) is passed in via env var
# by the caller. Generating real traffic and knowing which containers to
# toggle is the consumer's job.

TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

die() { echo "$1" >&2; exit "${2:-1}"; }

require_repo_root() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
  [ "$PWD" = "$repo_root" ] || die "must be run from repo root ($repo_root)"
}

# Dumps a timestamped snapshot of relevant container state on every failure,
# so a one-off teardown (containers actually gone) leaves a trail distinct
# from a transient check failure, instead of only the final error message.
fail() {
  echo "FAIL: $*" >&2
  echo "---- docker state at $(date -u +%FT%TZ) ----" >&2
  docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1 \
    | grep -E 'tempo|loki|prometheus|open-telemetry|grafana' >&2 || true
  echo "----" >&2
  exit 1
}

poll() {
  local tries="$1" delay="$2"; shift 2
  local n=0
  until "$@" >"$SCRATCH" 2>&1; do
    n=$((n + 1))
    [ "$n" -ge "$tries" ] && return 1
    sleep "$delay"
  done
  return 0
}

check_otel_prereqs() {
  poll 5 3 curl -sf "$TEMPO_URL/ready" || fail "Tempo unreachable at $TEMPO_URL after 15s — is this stack up (make run)?"
  # Loki's ingester reports 503 "waiting for 15s after being ready" for a bit
  # after startup — a real, known Loki behavior, not a sign anything is broken.
  poll 8 3 curl -sf "$LOKI_URL/ready" || fail "Loki unreachable at $LOKI_URL after 24s"
  poll 5 3 curl -sf "$PROM_URL/-/healthy" || fail "Prometheus unreachable at $PROM_URL after 15s"
}

require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || die "$name is required (set it in the environment, e.g. via 'make $2 $name=...')"
}
