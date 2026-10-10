#!/usr/bin/env bash
# Install the in-container autostart for the iris-fhir image: the container-local
# davinci-stack controller plus its systemd unit, both installed and enabled.
# Run INSIDE the container, as root, before packaging the image.
#
#   lxc-attach -n iris-fhir -- bash /opt/davinci-mock/bin/lxc-install-autostart.sh
#
# Idempotent. This is NOT the host-side wrapper (bin/davinci-stack.sh): that one
# lxc-starts the container and delegates to /usr/local/bin/davinci-stack, which
# is the file this script installs from bin/davinci-stack-container.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

[ "$(id -u)" = 0 ] || { echo "error: run as root, inside the container" >&2; exit 1; }
[ -d /run/systemd/system ] || { echo "error: no running systemd here — run this inside the container" >&2; exit 1; }

install -m 0755 "$ROOT/bin/davinci-stack-container.sh" /usr/local/bin/davinci-stack
install -m 0644 "$ROOT/fixtures/lxc/davinci-stack.service" /etc/systemd/system/davinci-stack.service
systemctl daemon-reload
systemctl enable davinci-stack.service

echo "installed /usr/local/bin/davinci-stack and enabled davinci-stack.service"
echo "it waits for IRIS (iris.service), then runs bin/up.sh + bin/seed-iris.sh."
