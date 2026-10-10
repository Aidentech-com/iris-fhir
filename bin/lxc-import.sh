#!/usr/bin/env bash
# Drop the iris-fhir LXC image in and start the whole DaVinci prior-auth stack.
# END-USER side. One file to download (or the GitHub release parts), one
# command, and the container boots IRIS + the six services itself.
#
# This script never starts or restarts lxc-net. It only checks that the bridge
# you need already exists — any bridge works, any subnet. The image defaults to
# lxcbr0 @ 10.0.3.1 with the container on 10.0.3.108; if your host uses a
# different bridge (e.g. br0 on a 192.168.x.0/24), pass --bridge and
# --container-ip and the extracted image is re-pinned before first start.
#
# Every step prints a one-line brief and waits for you to accept (Enter) or
# exit the whole process (x). Download progress is shown live.
#
#   Usage:
#     sudo bash bin/lxc-import.sh                          # single file from download.aidentech.com (default)
#     sudo bash bin/lxc-import.sh github                   # GitHub release parts
#     sudo bash bin/lxc-import.sh ./downloads              # dir with parts (+ .sha256)
#     sudo bash bin/lxc-import.sh iris-fhir-image.tar.gz   # single local file
#     sudo bash bin/lxc-import.sh <url> [<url> ...]        # raw part URLs
#
#   Options:
#     --bridge NAME      bridge to attach the container to (default: lxcbr0 @ 10.0.3.1)
#     --container-ip IP  static IP for the container (default: 10.0.3.108)
#     --yes, -y          accept every step without prompting (unattended)
#     --log FILE         transcript file (default: $HOME/lxc-import-iris-fhir.log)
set -euo pipefail

NAME=iris-fhir
DEST=/var/lib/lxc/$NAME
ARCHIVE_NAME="$NAME-image.tar.gz"
DEFAULT_BRIDGE="lxcbr0"
DEFAULT_BRIDGE_IP="10.0.3.1"
DEFAULT_IP="10.0.3.108"
DOWNLOAD_BASE="https://download.aidentech.com"
# GitHub's /releases/latest is an HTML page (it redirects to /releases/tag/<t>);
# json.load on it fails. Use the REST API, which returns the asset list as JSON.
RELEASE_API="https://api.github.com/repos/Aidentech-com/iris-fhir/releases/latest"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo bash $0 [OPTIONS] [SOURCE]

SOURCE   (default) download   single file from https://download.aidentech.com (~4.2 GB)
         github            GitHub release parts (3 x ~1.9 GB)
         ./dir | file.tar.gz | part-files | URLs   existing local sources

OPTIONS
  --bridge NAME       bridge to attach the container to (default: lxcbr0 @ 10.0.3.1)
  --container-ip IP   static IP for the container (default: 10.0.3.108)
  --yes, -y           accept every step without prompting (unattended)
  --log FILE          transcript file (default: \$HOME/lxc-import-iris-fhir.log)
EOF
}

# --- options ------------------------------------------------------------
BRIDGE_OPT="" IP_OPT="" YES=0 SRC_ARG="download" LOG="${LOG:-$HOME/lxc-import-iris-fhir.log}"
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bridge)       BRIDGE_OPT="${2:?--bridge needs a bridge name}"; shift 2;;
    --bridge=*)     BRIDGE_OPT="${1#*=}"; shift;;
    --container-ip|--ip) IP_OPT="${2:?--container-ip needs an IPv4 address}"; shift 2;;
    --container-ip=*|--ip=*) IP_OPT="${1#*=}"; shift;;
    --yes|-y)       YES=1; shift;;
    --log)          LOG="${2:?--log needs a file path}"; shift 2;;
    --help|-h)      usage; exit 0;;
    -*)             die "unknown option: $1";;
    *)              positional+=("$1"); shift;;
  esac
done
[ ${#positional[@]} -gt 0 ] && SRC_ARG="${positional[0]}"

STAGE="${TMPDIR:-/var/tmp}/lxc-import.$$"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

START=$(date +%s)
elapsed() { printf '%ss' "$(( $(date +%s) - START ))"; }

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '  \033[1;33m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[1;33mwarning:\033[0m %s\n' "$*"; }

# transcript: everything echoes to the terminal AND the log
mkdir -p "$(dirname "$LOG")"
printf '\n=== lxc import: %s  (%s) ===\n' "$NAME" "$(date -Is)" >> "$LOG"
exec > >(tee -a "$LOG") 2>&1

# --- step gate: brief -> accept or exit the whole process -----------------
STEP=0
TOTAL=10
begin_step() { # $1 title  $2 brief
  STEP=$(( STEP + 1 ))
  printf '\n\033[1;34m==> [%s/%s] %s\033[0m   (%s)\n' "$STEP" "$TOTAL" "$1" "$(elapsed)"
  printf '  %s\n' "$2"
  if [ "$YES" = 1 ]; then
    printf '  (--yes: continuing automatically)\n'
    return 0
  fi
  if [ ! -t 0 ]; then
    printf '  (stdin is not a terminal — continuing; use --yes to make this explicit)\n'
    return 0
  fi
  printf '  Press Enter to accept, or x to exit: '
  read -r ans || true
  case "${ans:-}" in
    x|X|q|Q|quit|exit) printf '  Exiting — nothing was changed.\n'; exit 1;;
  esac
}

# --- network helpers ------------------------------------------------------
bridge_inet()   { ip -4 addr show "$1" 2>/dev/null | awk '$1=="inet"{print $2; exit}'; }
bridge_addr()   { bridge_inet "$1" | cut -d/ -f1; }
bridge_prefix() { bridge_inet "$1" | cut -d/ -f2; }

ip_free() { # $1 ip -> 0 free / 1 busy
  local ip="$1"
  ip -4 addr show 2>/dev/null | grep -Fqw "$ip" && return 1
  grep -Fl "$ip" /var/lib/misc/dnsmasq.*.leases 2>/dev/null | grep -q . && return 1
  ping -c1 -W1 -q "$ip" >/dev/null 2>&1 && return 1
  return 0
}

valid_ip() { # $1 ip
  local ip="$1" o
  case "$ip" in
    *[!0-9.]*|*..*|.*|*.) return 1;;
  esac
  IFS=. read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    { [ -n "$o" ] && [ "$o" -ge 0 ] && [ "$o" -le 255 ]; } 2>/dev/null || return 1
  done
  return 0
}

# ==========================================================================
printf '\033[1;34m=== lxc image import: %s ===\033[0m\n' "$NAME"

# ---------------------------------------------------------------- [1/10]
begin_step "Host prerequisites" \
  "Checks: running as root, LXC tools installed, curl, and >= 15 GB free under /var/lib for the extraction."
[ "$(id -u)" = 0 ] || die "run as root (sudo bash $0)"
command -v lxc-start >/dev/null || die "lxc-utils not installed (apt install lxc lxc-utils)"
command -v lxc-info  >/dev/null || die "lxc-utils not installed (apt install lxc lxc-utils)"
command -v curl      >/dev/null || die "curl not installed"
avail="$(df -Pk /var/lib 2>/dev/null | awk 'NR==2{print $4}' || true)"
[ "${avail:-0}" -ge 15728640 ] || die "need >= 15 GB free under /var/lib (have $(( avail / 1024 / 1024 )) GB)"
ok "root, lxc tools, curl, disk"

# ---------------------------------------------------------------- [2/10]
begin_step "Network — bridge and container IP" \
  "Looks for the image default lxcbr0 @ 10.0.3.1. If absent, lists the bridges on this host and lets you pick one + an IP. Never starts or restarts lxc-net."
BRIDGE="$BRIDGE_OPT"
if [ -z "$BRIDGE" ]; then
  if [ "$(bridge_addr "$DEFAULT_BRIDGE")" = "$DEFAULT_BRIDGE_IP" ]; then
    BRIDGE="$DEFAULT_BRIDGE"
    info "default bridge $DEFAULT_BRIDGE found @ $DEFAULT_BRIDGE_IP"
  else
    warn "$DEFAULT_BRIDGE ($DEFAULT_BRIDGE_IP) not found. Bridges with an address on this host:"
    candidates=""
    for b in $(ip -4 addr show type bridge 2>/dev/null | awk -F': ' '/^[0-9]+:/{print $2}'); do
      a="$(bridge_addr "$b" || true)"
      [ -n "$a" ] || continue
      printf '    - %-16s %s\n' "$b" "$a/$(bridge_prefix "$b")"
      candidates="$candidates $b"
    done
    candidates="$(printf '%s\n' $candidates | sort -u | tr '\n' ' ')"
    if [ "$YES" = 1 ] || [ ! -t 0 ]; then
      BRIDGE="$(printf '%s\n' $candidates | head -1)"
      [ -n "$BRIDGE" ] || die "no bridge with an address exists. Create one yourself (this script never runs lxc-net):  systemctl restart lxc-net"
      info "non-interactive: using the first bridge found: $BRIDGE"
    else
      printf '  Type a bridge name to use it, or press Enter to abort: '
      read -r pick || true
      if [ -z "${pick:-}" ]; then
        die "no bridge chosen. Create the default one yourself (this script never runs lxc-net):  systemctl restart lxc-net"
      fi
      BRIDGE="$pick"
    fi
  fi
fi
GATEWAY="$(bridge_addr "$BRIDGE" || true)"
PREFIX="/$(bridge_prefix "$BRIDGE" || true)"
PREFIX="${PREFIX#//}"
[ -n "$GATEWAY" ] || die "bridge $BRIDGE exists but has no IPv4 address — assign one first, e.g. ip addr add 192.168.50.1/24 dev $BRIDGE"
[ "$PREFIX" = "/" ] && PREFIX="/24"

CONTAINER_IP="$IP_OPT"
if [ -z "$CONTAINER_IP" ]; then
  if [ "$BRIDGE" = "$DEFAULT_BRIDGE" ] && [ "$GATEWAY" = "$DEFAULT_BRIDGE_IP" ]; then
    CONTAINER_IP="$DEFAULT_IP"
  else
    sugg="$(printf '%s' "$GATEWAY" | awk -F. '{print $1"."$2"."$3".108"}')"
    if [ "$YES" = 1 ] || [ ! -t 0 ]; then
      CONTAINER_IP="$sugg"
      info "non-interactive: container IP = $CONTAINER_IP"
    else
      printf '  Container IP on %s (%s%s) [%s]: ' "$BRIDGE" "$GATEWAY" "$PREFIX" "$sugg"
      read -r ip2 || true
      CONTAINER_IP="${ip2:-$sugg}"
    fi
  fi
fi
valid_ip "$CONTAINER_IP" || die "not a valid IPv4 address: $CONTAINER_IP"
[ "$CONTAINER_IP" != "$GATEWAY" ] || die "container IP must differ from the bridge address ($GATEWAY)"
if [ "$BRIDGE" = "$DEFAULT_BRIDGE" ] && [ "$CONTAINER_IP" = "$DEFAULT_IP" ]; then REPIN=0; else REPIN=1; fi
ip_free "$CONTAINER_IP" || die "address $CONTAINER_IP is already in use on this host (another guest or a host address)"
info "using bridge $BRIDGE ($GATEWAY$PREFIX) -> container $CONTAINER_IP$PREFIX  [re-pin: $([ $REPIN = 1 ] && echo yes || echo 'no — image default')]"
ok "network resolved"

# ---------------------------------------------------------------- [3/10]
begin_step "Image source" \
  "Downloads the ~4.2 GB image. Default is the single file from https://download.aidentech.com; 'github' downloads the three release parts instead."
SRC="$SRC_ARG"
ARCHIVE="$STAGE/$ARCHIVE_NAME"
case "$SRC" in
  download)
    info "fetching $DOWNLOAD_BASE/$ARCHIVE_NAME (single file, ~4.2 GB)"
    curl -fL --progress-bar -o "$ARCHIVE" "$DOWNLOAD_BASE/$ARCHIVE_NAME"
    curl -fL -o "$STAGE/$ARCHIVE_NAME.sha256" "$DOWNLOAD_BASE/$ARCHIVE_NAME.sha256" \
      || warn "no .sha256 sidecar at the download link — checksum step will be skipped"
    ;;
  github)
    info "fetching release metadata from $RELEASE_API ..."
    api="$(curl -sfL -H 'Accept: application/vnd.github+json' "$RELEASE_API")" \
      || die "cannot reach the GitHub API at $RELEASE_API (offline, release missing, or anonymous rate limit)"
    assets="$(printf '%s' "$api" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(a["browser_download_url"] for a in d.get("assets",[])))' 2>/dev/null)" \
      || die "could not parse release metadata (GitHub API rate limit? open $RELEASE_API in a browser)"
    [ -n "$assets" ] || die "no downloadable assets found in the release"
    info "downloading parts from GitHub (each up to ~2 GB)..."
    for url in $assets; do
      [ -n "$url" ] || continue
      info "  $(basename "$url")"
      curl -sfL --progress-bar -o "$STAGE/$(basename "$url")" "$url"
    done
    ls "$STAGE"/"$ARCHIVE_NAME".part* >/dev/null 2>&1 || die "archive parts missing after download"
    cat "$STAGE"/"$ARCHIVE_NAME".part* > "$ARCHIVE"
    ;;
  *.tar.gz)
    cp "$SRC" "$ARCHIVE"
    [ -f "${SRC%.tar.gz}.sha256" ] && cp "${SRC%.tar.gz}.sha256" "$STAGE/$(basename "${SRC%.tar.gz}.sha256")"
    ;;
  *.part*)
    cat "$@" > "$ARCHIVE"
    ;;
  http*)
    n=0
    for url in "${positional[@]}"; do
      case "$url" in
        http*) curl -sfL --progress-bar -o "$STAGE/part$(printf '%02d' "$n")" "$url"; n=$(( n + 1 ));;
      esac
    done
    [ "$n" -gt 0 ] || die "no http(s) URLs given"
    cat "$STAGE"/part* > "$ARCHIVE"
    ;;
  *)
    [ -d "$SRC" ] || die "cannot read $SRC"
    if ls "$SRC"/"$ARCHIVE_NAME".part* >/dev/null 2>&1; then
      cat "$SRC"/"$ARCHIVE_NAME".part* > "$ARCHIVE"
    elif [ -f "$SRC/$ARCHIVE_NAME" ]; then
      cp "$SRC/$ARCHIVE_NAME" "$ARCHIVE"
    else
      die "no $ARCHIVE_NAME.part* files (or $ARCHIVE_NAME) in $SRC"
    fi
    [ -f "$SRC/$ARCHIVE_NAME.sha256" ] && cp "$SRC/$ARCHIVE_NAME.sha256" "$STAGE/"
    ;;
esac
[ -s "$ARCHIVE" ] || die "no archive assembled"
ok "download complete: $(du -h "$ARCHIVE" | cut -f1)"

# ---------------------------------------------------------------- [4/10]
begin_step "Verify the image" \
  "sha256sum -c the whole archive against the published sidecar. A mismatch stops here."
if [ -f "$STAGE/$ARCHIVE_NAME.sha256" ]; then
  ( cd "$STAGE" && sha256sum -c "$ARCHIVE_NAME.sha256" ) || die "checksum mismatch on the downloaded image — re-run, or download from the GitHub release"
  ok "archive checksum OK"
else
  warn "no .sha256 sidecar available — checksum skipped (the GitHub release ships sidecars; use 'github' for a verified pull)"
fi

# ---------------------------------------------------------------- [5/10]
begin_step "Replace any existing container" \
  "If an iris-fhir container already exists on this host it will be stopped and replaced — its state is lost."
if [ -e "$DEST" ]; then
  st="$(lxc-info -n "$NAME" -s -H 2>/dev/null || echo unknown)"
  info "existing container present on this host (state: $st). Replacing it wipes its state."
  if [ "$st" = RUNNING ]; then
    info "stopping the existing container (waiting for a clean stop)..."
    lxc-stop -n "$NAME" >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
      [ "$(lxc-info -n "$NAME" -s -H 2>/dev/null || true)" = STOPPED ] && break
      sleep 2
    done
    [ "$(lxc-info -n "$NAME" -s -H 2>/dev/null || true)" = STOPPED ] \
      || die "could not stop the existing container — stop it yourself and re-run (lxc-stop -n $NAME)"
  fi
  rm -rf "$DEST"
  ok "removed previous container"
else
  ok "no previous container — clean install"
fi
mkdir -p /var/lib/lxc

# ---------------------------------------------------------------- [6/10]
begin_step "Extract the image" \
  "Untars the archive under /var/lib/lxc (top-level directory: $NAME)."
tar -xzf "$ARCHIVE" -C /var/lib/lxc
[ -d "$DEST" ] || die "archive did not produce $DEST (wrong image?)"
grep -q "rootfs.path = dir:/var/lib/lxc/$NAME/rootfs" "$DEST/config" \
  || die "container config path mismatch; expected dir:/var/lib/lxc/$NAME/rootfs"
ok "extracted to $DEST"

# ---------------------------------------------------------------- [7/10]
repin_file() { # $1 path
  if [ ! -f "$1" ]; then warn "  $1 missing — skipped"; return 0; fi
  sed -i "s/10\.0\.3\.108/$CONTAINER_IP/g" "$1"
  ok "  ${1#"$DEST"/}"
}
if [ "$REPIN" = 1 ]; then
  begin_step "Re-pin network (custom bridge/IP)" \
    "The image bakes in $DEFAULT_BRIDGE / $DEFAULT_IP. Rewriting the container config, netplan, the installed systemd unit, and the stack's endpoint references so everything keys on $CONTAINER_IP on $BRIDGE. Runtime state (logs, IRIS data) is left untouched; the shipped Keycloak DB is dropped so the realm re-imports with your redirect URIs."
  handle="$DEST/rootfs"
  sed -i "s/^lxc\.net\.0\.link = .*/lxc.net.0.link = $BRIDGE/" "$DEST/config"
  ok "  config: lxc.net.0.link -> $BRIDGE"
  cat > "$handle/etc/netplan/10-lxc.yaml" <<EOF
# Static IP for the host's $BRIDGE bridge. The whole davinci-mock stack keys
# on $CONTAINER_IP:52774. Re-pinned by bin/lxc-import.sh for a custom bridge/IP.
network:
  ethernets:
    eth0:
      addresses:
        - $CONTAINER_IP$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $GATEWAY
          - 1.1.1.1
          - 8.8.8.8
  version: 2
EOF
  ok "  netplan -> $CONTAINER_IP$PREFIX via $GATEWAY"
  repin_file "$handle/opt/davinci-mock/bin/env.sh"
  repin_file "$handle/opt/davinci-mock/bin/seed-iris.sh"
  repin_file "$handle/opt/davinci-mock/bin/ehr-shim/server.js"
  repin_file "$handle/opt/davinci-mock/bin/up.sh"
  repin_file "$handle/opt/davinci-mock/bin/davinci-stack.sh"
  repin_file "$handle/opt/davinci-mock/bin/davinci-stack-container.sh"
  repin_file "$handle/usr/local/bin/davinci-stack"
  repin_file "$handle/opt/davinci-mock/fixtures/lxc/davinci-stack.service"
  # The installed unit is a separate copy of the fixture: systemd reads THIS one.
  repin_file "$handle/etc/systemd/system/davinci-stack.service"
  repin_file "$handle/opt/davinci-mock/fixtures/keycloak/BurdenReduction-realm.json"
  repin_file "$handle/opt/davinci-mock/fixtures/order-sign-warmup.json"
  # kc.sh --import-realm only imports when the realm is absent, and the image ships
  # the realm pre-imported (H2 DB) — so the re-pinned fixture alone would never take
  # effect. Drop the shipped DB; first boot re-imports from the re-pinned fixture.
  rm -f "$handle/opt/keycloak/data/h2/keycloakdb.mv.db" \
        "$handle/opt/keycloak/data/h2/keycloakdb.trace.db"
  ok "shipped Keycloak DB dropped (realm re-imports with $CONTAINER_IP redirect URIs)"
  if grep -rn '10\.0\.3\.108' "$DEST/config" "$handle/etc/netplan/10-lxc.yaml" \
      "$handle/opt/davinci-mock/bin/env.sh" "$handle/opt/davinci-mock/bin/seed-iris.sh" \
      "$handle/opt/davinci-mock/bin/ehr-shim/server.js" \
      "$handle/usr/local/bin/davinci-stack" \
      "$handle/etc/systemd/system/davinci-stack.service" \
      "$handle/opt/davinci-mock/fixtures/keycloak/BurdenReduction-realm.json" \
      "$handle/opt/davinci-mock/fixtures/order-sign-warmup.json" 2>/dev/null; then
    warn "10.0.3.108 still appears in a re-pinned file (listed above) — review before starting"
  fi
  [ -f "$handle/opt/keycloak/data/h2/keycloakdb.mv.db" ] \
    && warn "shipped Keycloak DB still present — realm keeps its baked redirect URIs"
  ok "re-pinned to $CONTAINER_IP on $BRIDGE"
else
  info "image default network (lxcbr0 / $DEFAULT_IP) — no re-pin needed"
fi

# ---------------------------------------------------------------- [8/10]
begin_step "Start the container" \
  "lxc-start -n $NAME — the container boots IRIS and the six-service stack itself (no host services involved)."
lxc-start -n "$NAME" 2>/dev/null || true
for i in $(seq 1 45); do
  [ "$(lxc-info -n "$NAME" -s -H 2>/dev/null)" = RUNNING ] && break
  sleep 2
done
[ "$(lxc-info -n "$NAME" -s -H 2>/dev/null)" = RUNNING ] || die "container did not start (see /var/log/lxc/$NAME.log)"
ok "container RUNNING"

# ---------------------------------------------------------------- [9/10]
begin_step "Verify the stack" \
  "Waits for IRIS FHIR (https://$CONTAINER_IP:52774), the davinci-stack unit, then probes all six services on $CONTAINER_IP — each must answer 200."
code=""
for i in $(seq 1 30); do
  code="$(curl -sk --max-time 5 "https://$CONTAINER_IP:52774/fhir/r4/metadata" -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
  [ "$code" = 200 ] && break
  sleep 3
done
if [ "$code" != 200 ]; then
  warn "IRIS did not answer on https://$CONTAINER_IP:52774 yet — another host on that address? see /var/lib/misc/dnsmasq.*.leases"
fi
st=""
for i in $(seq 1 90); do
  st="$(lxc-attach -n "$NAME" -- systemctl is-active davinci-stack.service 2>/dev/null || true)"
  [ "$st" = active ] && break
  sleep 2
done
if [ "$st" != active ]; then
  warn "davinci-stack.service not active yet — inside the container: tail /var/log/davinci-stack.log"
fi
stack_ready() {
  while read -r name port route; do
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$CONTAINER_IP:$port$route" 2>/dev/null || echo 000)"
    [ "$c" = 200 ] || return 1
  done <<'EOF'
keycloak     8180 /realms/BurdenReduction/.well-known/openid-configuration
ehr-shim     8080 /fhir/r4/metadata
crd          8090 /r4/cds-services
prior-auth   9015 /fhir/metadata
dtr          3005 /
crg          3001 /
EOF
  return 0
}
for i in $(seq 1 30); do
  stack_ready && break
  [ "$i" = 30 ] || sleep 4
done
printf '  %-12s %s  %s  %s\n' SERVICE PORT CODE ROUTE
while read -r name port route; do
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$CONTAINER_IP:$port$route" 2>/dev/null || echo 000)"
  printf '  %-12s %s  %s  %s\n' "$name" "$port" "$c" "$route"
done <<'EOF'
keycloak     8180 /realms/BurdenReduction/.well-known/openid-configuration
ehr-shim     8080 /fhir/r4/metadata
crd          8090 /r4/cds-services
prior-auth   9015 /fhir/metadata
dtr          3005 /
crg          3001 /
EOF

# --------------------------------------------------------------- [10/10]
printf '\n\033[1;34m==> [10/10] Summary\033[0m   (%s)\n' "$(elapsed)"
lxc-ls -f | grep "$NAME" || true
echo
echo "IRIS FHIR backend: ${code:-000}  (https://$CONTAINER_IP:52774/fhir/r4)"
echo "Six-service stack:  see table above — all six should be 200."
[ "$REPIN" = 1 ] && echo "Re-pinned for:      $CONTAINER_IP on $BRIDGE (Keycloak redirect URIs updated)"
echo
echo "Open http://$CONTAINER_IP:3001/ and follow the browser walkthrough in README.md."
echo "Optional drivers (both required to certify a run):"
echo "  lxc-attach -n $NAME -- bash -c 'cd /opt/davinci-mock && bash bin/demo.sh'           # 12/12"
echo "  ADVERTISE_HOST=$CONTAINER_IP ./.venv/bin/python bin/e2e-browser.py                  # 14/14"
echo "Transcript: $LOG"
echo "Full runbook: README.md"