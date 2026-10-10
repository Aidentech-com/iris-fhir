#!/usr/bin/env bash
# davinci-stack — inside-container lifecycle control for the DaVinci prior-auth
# stack. This is the CONTAINER-local variant: it manages only the six stack
# services (keycloak, ehr-shim, crd, prior-auth, dtr, crg) that live in this
# container's /opt/davinci-mock. IRIS and the container itself are the host's /
# init's business. Host-side davinci-stack (which lxc-starts/stops the
# container) is the /usr/local/bin/davinci-stack on the HOST.
#
# The whole point of the drop-in image: boot the container, IRIS starts via the
# baked-in iris.service, this unit (davinci-stack.service) brings up the six
# services, so the ONLY thing a host does is `lxc-start`.
#
#   davinci-stack start    IRIS 200 -> six services -> seed (idempotent)
#   davinci-stack stop     six services down (IRIS untouched)
#   davinci-stack status   IRIS + per-service probe table
#
# Installed to /usr/local/bin/davinci-stack by bin/lxc-install-autostart.sh
# (see fixtures/lxc/davinci-stack.service for the unit).
set -uo pipefail

REPO="/opt/davinci-mock"
IRIS_URL="https://10.0.3.108:52774/fhir/r4/metadata"
LOG="/var/log/davinci-stack.log"
ADVERTISE_HOST="${ADVERTISE_HOST:-10.0.3.108}"

# The six probes that actually answer (not /actuator, not /metadata guesses).
PORTS="$(cat <<'EOF'
keycloak     8180 /realms/BurdenReduction/.well-known/openid-configuration
ehr-shim     8080 /fhir/r4/metadata
crd          8090 /r4/cds-services
prior-auth   9015 /fhir/metadata
dtr          3005 /
crg          3001 /
EOF
)"

stamp() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

probe() { # name port route -> HTTP code
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://localhost:$2$3" 2>/dev/null || echo 000
}

stack_up() { # 0 iff all six answer 200; silent
  local name port route code bad=0
  while read -r name port route; do
    code="$(probe "$name" "$port" "$route")"
    [ "$code" = 200 ] || bad=1
  done <<<"$PORTS"
  return "$bad"
}

show_failures() {
  local name port route code
  while read -r name port route; do
    code="$(probe "$name" "$port" "$route")"
    printf '  FAIL %-12s %-6s %s  %s\n' "$name" "$port" "$code" "$route"
  done <<<"$PORTS"
}

wait_iris() { # up to $1 seconds for TLS 200 on the FHIR metadata endpoint
  local limit="${1:-180}" code i
  for ((i = 0; i < limit; i += 3)); do
    code="$(curl -sk --max-time 4 "$IRIS_URL" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
    [ "$code" = 200 ] && return 0
    sleep 3
  done
  return 1
}

start() {
  stamp "=== start (ADVERTISE_HOST=$ADVERTISE_HOST) ==="
  wait_iris || { stamp "error: IRIS did not answer $IRIS_URL"; return 1; }
  stamp "IRIS FHIR TLS 200"

  if stack_up; then
    stamp "all six services already up — skipping up.sh"
  else
    stamp "bin/up.sh"
    ( cd "$REPO" && ADVERTISE_HOST="$ADVERTISE_HOST" bash bin/up.sh ) >>"$LOG" 2>&1 \
      || { stamp "error: up.sh failed (see $LOG)"; return 1; }
  fi

  stamp "bin/seed-iris.sh (asserts the 9 IRIS queries)"
  ( cd "$REPO" && bash bin/seed-iris.sh ) >>"$LOG" 2>&1 \
    || stamp "warning: seed-iris.sh exited non-zero"

  if stack_up; then
    stamp "=== start OK: all six services green ==="
    return 0
  fi
  stamp "=== start FAILED: at least one service not 200 ==="
  show_failures
  return 1
}

stop() {
  stamp "=== stop ==="
  ( cd "$REPO" && bash bin/down.sh ) >>"$LOG" 2>&1 \
    || stamp "warning: down.sh exited non-zero"
  local name port route code tries all_down
  for tries in $(seq 1 40); do
    all_down=1
    while read -r name port route; do
      code="$(probe "$name" "$port" "$route")"
      [ "$code" = "000" ] || all_down=0
    done <<<"$PORTS"
    [ "$all_down" = 1 ] && break
    sleep 3
  done
  stamp "=== stop complete ==="
}

status() {
  echo "iris      : $(curl -sk --max-time 4 "$IRIS_URL" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)  $IRIS_URL"
  local name port route code
  while read -r name port route; do
    code="$(probe "$name" "$port" "$route")"
    printf '  %-12s %-6s %s  %s\n' "$name" "$port" "$code" "$route"
  done <<<"$PORTS"
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
