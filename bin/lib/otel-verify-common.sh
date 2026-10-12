# Shared by bin/*-verify-otel-*.sh — prereq checks, backend OTel javaagent
# toggle/restore, and a retry-with-delay helper. Not standalone; sourced,
# not executed.
#
# These scripts verify that a real downstream consumer (currently harrier +
# harrier-backend) is actually landing traces/logs/metrics in this stack —
# not just that the stack itself is configured. Override the HARRIER_*/
# FRONTEND_URL/*_URL vars below to point at a different consumer.

TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:5174}"
HARRIER_BACKEND_DIR="${HARRIER_BACKEND_DIR:-$HOME/go/src/github.com/CBA-General/harrier-backend}"
FRONTEND_CONTAINER="${FRONTEND_CONTAINER:-harrier-frontend-otel}"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-harrier-backend-app-1}"

die() { echo "$1" >&2; exit "${2:-1}"; }

require_repo_root() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
  [ "$PWD" = "$repo_root" ] || die "must be run from repo root ($repo_root)"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

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
  docker inspect "$FRONTEND_CONTAINER" >/dev/null 2>&1 || fail "$FRONTEND_CONTAINER is not running (see harrier's make docker-up-otel)"
  docker inspect "$BACKEND_CONTAINER" >/dev/null 2>&1 || fail "$BACKEND_CONTAINER is not running"
  poll 5 3 curl -sf "$TEMPO_URL/ready" || fail "Tempo unreachable at $TEMPO_URL after 15s — is this stack up (make run)?"
  # Loki's ingester reports 503 "waiting for 15s after being ready" for a bit
  # after startup — a real, known Loki behavior, not a sign anything is broken.
  poll 8 3 curl -sf "$LOKI_URL/ready" || fail "Loki unreachable at $LOKI_URL after 24s"
  poll 5 3 curl -sf "$PROM_URL/-/healthy" || fail "Prometheus unreachable at $PROM_URL after 15s"
}

# Sets WAS_ENABLED so restore_backend_otel can put things back as found.
ensure_backend_otel_enabled() {
  WAS_ENABLED=false
  if docker exec "$BACKEND_CONTAINER" sh -c "ps aux | grep -q '[-]javaagent'"; then
    WAS_ENABLED=true
  fi
  if [ "$WAS_ENABLED" = "false" ]; then
    echo "backend OTel is currently off — enabling temporarily for this test"
    (cd "$HARRIER_BACKEND_DIR" && OTEL_ENABLED=true docker compose --profile local up -d --no-deps app) >/dev/null
    echo "waiting for backend to restart with the javaagent attached..."
    sleep 15
  fi
}

restore_backend_otel() {
  if [ "${WAS_ENABLED:-true}" = "false" ]; then
    echo "== restoring backend to OTEL_ENABLED=false =="
    (cd "$HARRIER_BACKEND_DIR" && OTEL_ENABLED=false docker compose --profile local up -d --no-deps app) >/dev/null
  fi
}
