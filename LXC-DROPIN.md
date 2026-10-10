# LXC-DROPIN.md — the iris-fhir LXC image: end-to-end from a fresh Ubuntu host

This repo + a single prebuilt LXC image = the complete DaVinci prior-auth E2E
(**CRD → DTR → PAS**) running against an IRIS FHIR server. The image is
**self-contained**: IRIS, all six DaVinci services (Keycloak, CRD, dtr, crg,
prior-auth, ehr-shim), their toolchains (Temurin JDK 17, Maven, and a JDK 21 for
Keycloak), the pinned upstream checkouts and the built frontends all live
*inside* the container. Your host needs nothing but LXC itself — no Node, no JDK,
no `provision.sh`.

**`lxc-start` is the whole flow.** The container boots IRIS via its own
`iris.service`, then `davinci-stack.service` waits for IRIS and brings up the six
services (`bin/up.sh` + `bin/seed-iris.sh`). You open
**<http://10.0.3.108:3001/>** and click through the coverage card → Keycloak
login → questionnaire → **Proceed To Prior Auth** → claim goes `Pending` then
`Granted`.

Target: **Ubuntu 24.04, root, ~12 GB free disk, LXC**. First boot ≈ 1–2 min; no
provisioning step, no build step.

---

## The contract you're agreeing to

| Thing | Value | Must be true on your host |
|---|---|---|
| Container IP | **10.0.3.108** (static, inside the image) | default `lxcbr0` from lxc-net — nothing else on `.108` |
| Browser entry point | **<http://10.0.3.108:3001/>** (crd-request-generator) | reachable from the machine you browse from |
| Six services | keycloak 8180 · ehr-shim 8080 · crd 8090 · prior-auth 9015 · dtr 3005 · crg 3001 | all bound `0.0.0.0` inside the container |
| IRIS FHIR (TLS) | `https://10.0.3.108:52774/fhir/r4` | reachable from the host |
| Mock TLS cert | self-signed `CN=iris-fhir`, public copy in `bin/ehr-shim/iris-fhir.crt` | the ehr-shim trusts it; your curl needs `-k` or the `.crt` |
| IRIS OAuth fixture | confidential client baked into the image | matches `bin/env.sh` defaults — **do not rotate** unless you rebuild the image |
| Superuser | IRIS `_SYSTEM` account (install-time password) | you never need it for the E2E |

**Licensing note:** IRIS for Health Community is InterSystems' free
development/demo distribution. This image redistributes that proprietary
software, so confirm the community license covers your use before going beyond
a demo. The image is shared as-is, with mock data only.

**Design note:** IRIS is proprietary and multi-GB and cannot be rebuilt from a
script; everything else is open-source and reproduced from pinned SHAs
(`versions.lock`). The image ships both halves preassembled so the only thing a
host does is `lxc-start`; the repo carries the scripts, drivers and pin set that
produced it, so the run stays reproducible and reviewable in git.

---

## Step 0 — one-time host prep (2 min)

```bash
sudo apt update && sudo apt install -y lxc curl python3
sudo systemctl restart lxc-net      # creates lxcbr0 (10.0.3.1) if not up
ip -4 addr show lxcbr0              # expect 10.0.3.1/24
```

## Step 1 — drop the image in (5–10 min, mostly download)

```bash
git clone https://github.com/Aidentech-com/iris-fhir.git
cd iris-fhir
sudo bash bin/lxc-import.sh github
```

That downloads the release parts, verifies checksums, extracts under
`/var/lib/lxc/iris-fhir`, and starts the container. From that point the container
brings itself up — the import script only waits for IRIS to answer:

```bash
curl -sk https://10.0.3.108:52774/fhir/r4/metadata -o /dev/null -w '%{http_code}\n'   # 200
lxc-ls -f | grep iris-fhir                                                            # RUNNING
```

Alternatives to `github` as the source argument: a local directory of parts, a
single `.tar.gz`, or explicit asset URLs. If the remote is unreachable you can
download manually: open the release page
`https://github.com/Aidentech-com/iris-fhir/releases/latest`, grab every
`iris-fhir-image.tar.gz.partNN` file + `parts.sha256`, put them in one dir and
`sudo bash bin/lxc-import.sh <that-dir>`.

## Step 2 — wait for the stack, then verify (1–2 min)

There is no provisioning and no `up.sh` to run on the host — the container's
`davinci-stack.service` does it. Wait for it, then probe all six from the host.
These are the endpoints that actually answer (not `/actuator`, not `/metadata`
guesses):

```bash
for i in $(seq 1 60); do
  lxc-attach -n iris-fhir -- systemctl is-active davinci-stack.service 2>/dev/null \
    | grep -q active && break
  sleep 5
done

while read -r name port route; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://10.0.3.108:$port$route" || echo 000)
  printf '  %-12s %s  %s\n' "$name" "$port" "$code"
done <<'EOF'
keycloak     8180 /realms/BurdenReduction/.well-known/openid-configuration
ehr-shim     8080 /fhir/r4/metadata
crd          8090 /r4/cds-services
prior-auth   9015 /fhir/metadata
dtr          3005 /
crg          3001 /
EOF
```

All six must be `200`. The bring-up log is `/var/log/davinci-stack.log` inside
the container (`lxc-attach -n iris-fhir -- tail /var/log/davinci-stack.log`); it
ends with `=== start OK: all six services green ===`.

## Step 3 — verify the E2E (5 min)

Both drivers are required; neither covers the other (see AGENTS.md). The stack
repo travels inside the image at `/opt/davinci-mock`, so the API driver runs
there:

```bash
# inside the container — API surface
lxc-attach -n iris-fhir -- bash -c 'cd /opt/davinci-mock && bash bin/demo.sh'
#   → 12 assertions, 0 failures

# from the host — real browser (needs the repo's bin/e2e-browser.py + Playwright)
ADVERTISE_HOST=10.0.3.108 python3 bin/e2e-browser.py
#   → 14 passed, 0 failed
```

`e2e-browser.py` needs Playwright once:
`pip install playwright && playwright install chromium --with-deps`

Then open **<http://10.0.3.108:3001/>** and click through: coverage card →
Keycloak login (`dtr` / `dtr-demo`) → questionnaire → **Proceed To Prior Auth**
→ claim goes Pending then Granted.

---

## What's actually inside the image

- Ubuntu 24.04 + IRIS for Health Community **2026.2.0.221.0** at `/opt/iris`,
  Apache + CSP serving FHIR R4 on `:52774` (TLS) and `:52773`.
- The generated OAuth confidential client (`ConfigureInternalOAuthClients`),
  matching `bin/env.sh` — this is what the ehr-shim uses to mint bearer tokens.
- The DaVinci seed (patients pat013/pat015, device requests, coverage) loaded by
  `bin/seed-iris.sh`, idempotent on re-run.
- **The whole six-service stack, pre-provisioned**: `/opt/davinci-mock` holds the
  JDK 17 + Maven toolchains, all six pinned upstream checkouts, `node_modules`
  and the built dtr/crg frontends; Keycloak 26.7.4 lives at `/opt/keycloak`; the
  Gradle cache (`/root/.cache/davinci-mock`) is warm. First boot needs no network
  and no build.
- **JDK 21 for Keycloak** at `/usr/lib/jvm/java-21-openjdk-amd64`, *including* its
  Debian-packaged `/etc` config: `/etc/java-21-openjdk/` and
  `/etc/ssl/certs/java/cacerts`. These are not optional — without the first
  `kc.sh` dies loading `java.security`; without the second it dies with "could not
  find the system truststore". `provision.sh` installs Keycloak but not these, so
  a packager must ensure they are present (they are, in this image).
- Trimmed for transport: no installer kit, apt caches, or files under `/var/log`,
  `/tmp`, `/opt/iris/httpd/logs`. The IRIS WIJ, journals and `journal.log` ship
  **as-is** — deleting them makes IRIS believe the shutdown was abnormal and the
  box boots into single-user journal recovery (hit 2026-09-30, recovered, then
  excluded from the recipe).
  It is split with `split -b 1800M` for the GitHub release asset limit
  (≤1.9 GB each). The `dropin-v2` build (2026-10-10) produced a **4.2 GB**
  compressed archive in **3 parts** (`part00` 1.8 GB, `part01` 1.8 GB,
  `part02` 629 MB) plus `parts.sha256`; `bin/lxc-image-build.sh` prints the
  sizes for any rebuild.
- IRIS **auto-starts** at container boot via a baked-in `iris.service` systemd
  unit (`iris start FHIR`); its ExecStop shuts IRIS down inside a pty (the
  `iris stop` prompts read `/dev/tty` and would EOF-fail under plain systemd),
  so host reboots / `lxc-stop` leave a clean WIJ marker. The six services
  auto-start via `davinci-stack.service` (enabled, `After=iris.service`).
- `iris list` shows **`state: warn`** — expected, not a fault: IRIS Health's
  failover context has no mirror partner configured and the journal's primary
  vs archive directory are the same (single-disk install). FHIR serving is
  unaffected (it announces at every start since provisioning).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `lxc-import.sh github` can't download | release not published yet, or repo visibility; download parts manually from the release page and pass the dir |
| container starts but `52774` hangs | another host took `10.0.3.108`; check `cat /var/lib/misc/dnsmasq.lxcbr0.leases`; free the IP or change `IRIS_FHIR_BASE` in `env.sh` + the container's `/etc/netplan/10-lxc.yaml` (`netplan apply`, `lxc-stop/start`) |
| `10.0.3.108:3001` unreachable but the container is RUNNING | the stack is still coming up (`davinci-stack.service` waits for a warm first boot); watch `/var/log/davinci-stack.log` and re-probe — allow ~2 min |
| keycloak `8180` probes `000` from the host but `200` inside | keycloak bound loopback only; `bin/up.sh` pins `KC_HTTP_HOST=0.0.0.0` for exactly this. Restart via the container's `davinci-stack stop && davinci-stack start` (it picks up the pinned bind) |
| six probes green but browser e2e fails at the SMART launch | CRD's write-once doc-needed flag got poisoned by a POST that wasn't `up.sh` (see AGENTS.md trap 6); restart CRD so `up.sh`'s warmup is its first POST |
| `downloads` dir import fails checksum | re-download parts; `sha256sum -c parts.sha256` names the bad file |
| `iris list` shows `state: warn` | expected — unconfigured HealthShare failover context; benign, serving unaffected |
| Windows / WSL2 host | the container + stack work, but a **Windows GUI browser cannot reach `10.0.3.108`** through the WSL2 NAT — browse from the Linux side, or port-forward. Native Ubuntu is the supported host |

## Rebuilding the image (maintainers only)

On the machine that owns the blessed container, after re-seeding or upgrading
IRIS or the stack:

```bash
sudo bash bin/lxc-image-build.sh        # stop→trim→tar→split→sha into /root/lxc-dist
```

The script refuses to package a DHCP-configured container — the static IP is
part of the image contract.

**What must be in the container before packaging** (all present in this image;
re-verify after any change):

- `bin/provision.sh --check` → "all inputs present" (run it *inside* the
  container, where the repo lives at `/opt/davinci-mock`).
- CDS-Library placed by `provision.sh` step 1b — CRD's whole library at
  `repos/CRD/server/CDS-Library/`, PAS's `PriorAuth/` at
  `repos/prior-auth/CDS-Library/`. Missing it is a hard exit at boot
  (`cds-services`/`fhir/metadata` never come up).
- The JDK 21 `/etc` dependencies above (`/etc/java-21-openjdk`,
  `/etc/ssl/certs/java/cacerts`).
- The six services built (`node_modules`, dtr/crg frontends) so first boot is
  fast and offline.
- **The in-container autostart installed.** `bin/lxc-install-autostart.sh`
  (run *inside* the container) installs `/usr/local/bin/davinci-stack` from
  `bin/davinci-stack-container.sh` and enables `fixtures/lxc/davinci-stack.service`
  (`After=`/`Requires=iris.service`, `Environment=ADVERTISE_HOST=10.0.3.108`,
  `ExecStart=/usr/local/bin/davinci-stack start`). Without it the container
  boots IRIS but never starts the six services.

**Ship only after a cold-boot re-verify**: `lxc-stop` → `lxc-start`, then confirm
`iris.service` and `davinci-stack.service` both `active`, all six probes `200`
from the host via `10.0.3.108`, `grep -c "Startup aborted"` in IRIS `messages.log`
= 0, and both drivers green (`demo.sh` in-container 12/12, `e2e-browser.py` from
the host 14/14 with `ADVERTISE_HOST=10.0.3.108`).
