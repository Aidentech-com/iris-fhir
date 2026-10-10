#!/usr/bin/env bash
# davinci-stack — systemd-facing lifecycle control for the DaVinci prior-auth
# stack: the iris-fhir LXC container (IRIS for Health FHIR engine) plus the
# six stack services (keycloak, ehr-shim, crd, prior-auth, dtr, crg).
#
# Installed as /usr/local/bin/davinci-stack (symlink -> this file) and driven
# by /etc/systemd/system/davinci-stack.service (systemctl enable davinci-stack).
# Boot-critical, so the boot path is the symlink on host-local ext4, NOT the
# repo path (the repo lives on a mount that may not be up at boot).
#
#   davinci-stack start    container up -> IRIS 200 -> six services -> seed
#   davinci-stack stop     six services down -> container stopped
#   davinci-stack status   container + IRIS + per-service probe table
#
# Idempotent: start with everything already green is a no-op; partial state
# is healed, not clobbered.
set -uo pipefail

REPO="/mnt/c/Users/FirstName.LastName/Downloads/davinci-mock"
CONTAINER="iris-fhir"
IRIS_URL="https://10.0.3.108:52774/fhir/r4/metadata"
LOG="/var/log/davinci-stack.log"
NODE_DIR="/root/.nvm/versions/node/v22.23.1/bin"

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

if [ -d "$NODE_DIR" ]; then
  export PATH="$NODE_DIR:$PATH"
elif command -v node >/dev/null 2>&1; then
  export PATH="$(dirname "$(command -v node)"):$PATH"
fi
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

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

container_running() { [ "$(lxc-info -n "$CONTAINER" -s -H 2>/dev/null)" = "RUNNING" ]; }

wait_iris() { # up to $1 seconds for TLS 200 on the FHIR metadata endpoint
  local limit="${1:-120}" code i
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

  wait_iris || { stamp "error: IRIS did not answer $IRIS_URL"; return 1; }
  stamp "IRIS FHIR TLS 200"

  if stack_up; then
    stamp "all six services already up — skipping up.sh"
  else
    stamp "bin/up.sh"
    ( cd "$REPO" && bash bin/up.sh ) >>"$LOG" 2>&1 \
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
  if container_running; then
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