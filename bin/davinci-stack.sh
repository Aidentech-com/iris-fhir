#!/usr/bin/env bash
# davinci-stack — HOST-side lifecycle control for the DaVinci prior-auth stack.
#
# The stack is now SELF-CONTAINED inside the iris-fhir LXC container: the six
# services (keycloak, ehr-shim, crd, prior-auth, dtr, crg) live inside the
# container and are driven by the container's own davinci-stack.service at
# boot (which waits for IRIS, then runs up.sh + seed-iris.sh). This host-side
# wrapper exists purely as a dev-box convenience: it starts/stops the
# container and delegates service control to the container via lxc-attach.
# An end user does not need it at all — `lxc-start` alone is the whole flow.
#
#   davinci-stack start    lxc-start -> IRIS 200 -> davinci-stack start inside
#   davinci-stack stop     davinci-stack stop inside -> container stopped
#   davinci-stack status   container + IRIS + per-service probes (host side)
#
# Idempotent: start with everything already green is a no-op; partial state
# is healed, not clobbered.
set -uo pipefail

CONTAINER="iris-fhir"
IRIS_URL="https://10.0.3.108:52774/fhir/r4/metadata"
LOG="/var/log/davinci-stack.log"

# The six probes as seen FROM THE HOST: the container's bridge IP, not
# localhost — the services do not run on the host anymore.
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

probe_host() { # name port route -> HTTP code via 10.0.3.108
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://10.0.3.108:$2$3" 2>/dev/null || echo 000
}

stack_up() { # 0 iff all six answer 200 from the host; silent
  local name port route code bad=0
  while read -r name port route; do
    code="$(probe_host "$name" "$port" "$route")"
    [ "$code" = 200 ] || bad=1
  done <<<"$PORTS"
  return "$bad"
}

show_failures() {
  local name port route code
  while read -r name port route; do
    code="$(probe_host "$name" "$port" "$route")"
    printf '  FAIL %-12s %-6s %s  %s\n' "$name" "$port" "$code" "$route"
  done <<<"$PORTS"
}

container_running() { [ "$(lxc-info -n "$CONTAINER" -s -H 2>/dev/null)" = "RUNNING" ]; }

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
  stamp "=== start ==="
  ip -4 addr show lxcbr0 2>/dev/null | grep -q '10\.0\.3\.1' \
    || stamp "warning: lxcbr0 (10.0.3.1) not found — enable lxc-net first"

  if ! container_running; then
    stamp "lxc-start $CONTAINER"
    lxc-start -n "$CONTAINER" || { stamp "error: lxc-start failed"; return 1; }
    for _ in $(seq 1 60); do container_running && break; sleep 2; done
  fi
  container_running || { stamp "error: container did not reach RUNNING"; return 1; }
  stamp "container $CONTAINER RUNNING"

  # The container's own davinci-stack.service (enabled at boot) brings up the
  # six services after IRIS; this attach is belt-and-braces for the case where
  # the container was started by hand outside systemd's unit ordering, and is
  # a no-op when everything is already green.
  wait_iris || { stamp "error: IRIS did not answer $IRIS_URL"; return 1; }
  stamp "IRIS FHIR TLS 200"
  if stack_up; then
    stamp "all six services already up (host view) — skipping attach"
  else
    stamp "lxc-attach $CONTAINER davinci-stack start"
    lxc-attach -n "$CONTAINER" -- /usr/local/bin/davinci-stack start \
      || { stamp "error: in-container davinci-stack start failed"; return 1; }
  fi

  stamp "lxc-attach $CONTAINER seed-iris.sh (asserts the 9 IRIS queries)"
  lxc-attach -n "$CONTAINER" -- bash -c 'cd /opt/davinci-mock && bash bin/seed-iris.sh' \
    >>"$LOG" 2>&1 || stamp "warning: seed-iris.sh exited non-zero"

  if stack_up; then
    stamp "=== start OK: all six services green (host view) ==="
    return 0
  fi
  stamp "=== start FAILED: at least one service not 200 ==="
  show_failures
  return 1
}

stop() {
  stamp "=== stop ==="
  if container_running; then
    stamp "lxc-attach $CONTAINER davinci-stack stop (six services down)"
    lxc-attach -n "$CONTAINER" -- /usr/local/bin/davinci-stack stop >>"$LOG" 2>&1 \
      || true
    stamp "lxc-stop $CONTAINER (clean unit shutdown inside)"
    lxc-stop -n "$CONTAINER" -t 60 || true
  fi
  stamp "=== stop complete ==="
}

status() {
  echo "container: $(lxc-info -n "$CONTAINER" -s -H 2>/dev/null || echo missing)"
  echo "iris      : $(curl -sk --max-time 4 "$IRIS_URL" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)  $IRIS_URL"
  local name port route code
  while read -r name port route; do
    code="$(probe_host "$name" "$port" "$route")"
    printf '  %-12s %-6s %s  %s\n' "$name" "$port" "$code" "$route"
  done <<<"$PORTS"
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac