#!/usr/bin/env bash
# Build the stack's inputs from versions.lock: 6 upstream clones, the JDK, Maven
# and Keycloak. CDS-Library placement is also done here (step 1b) — upstream
# never creates those dirs; ports and env live in bin/env.sh and bin/up.sh.
#
#   bin/provision.sh            provision anything missing, verify anything present
#   bin/provision.sh --check    verify only; never download, non-zero if incomplete
#
# Idempotent: safe to re-run after editing versions.lock, and safe to run on a
# machine where the stack is already up (it does not touch running processes).
#
# Every step here asserts. That is the design rule, and it is not stylistic:
# each of these inputs fails *silently* hours later rather than here --
#   CDS-Library in the wrong dir  -> hard exit at crd boot
#   global PORT exported         -> dtr hijacked onto 3001, stack still probes green
#   VSAC_CACHE_DIR without '/'   -> all 65 value sets "added", all lookups miss
#   Keycloak absent              -> demo.sh 12/12, first browser click fails
# Deferring the check to first boot is how the last three were found.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
lock="$root/versions.lock"
mode="${1:-}"

# --- output helpers ---------------------------------------------------------
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sok%s   %s\n' "$G" "$N" "$*"; }
warn() { printf '  %swarn%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
# Counts absent inputs so --check can exit non-zero. A --check that always exits
# 0 is not a check.
MISSING=0
missing() { MISSING=$((MISSING + 1)); printf '  %swarn%s %s\n' "$Y" "$N" "$*"; }

CHECK_ONLY=0
case "$mode" in
  "")      ;;
  --check) CHECK_ONLY=1 ;;
  *)       die "unknown argument '$mode' (expected nothing, or --check)" ;;
esac

# --- parse versions.lock ----------------------------------------------------
# Comment lines start at column 0. Sections are [repos] then [tooling], and
# section headers are matched before the comment test so a header is never
# mistaken for either.
[ -f "$lock" ] || die "no versions.lock at $lock"
declare -A REPO_SLUG REPO_SHA
declare -A TOOL
section=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '[repos]')   section=repos;   continue ;;
    '[tooling]') section=tooling; continue ;;
    '#'*)        continue ;;
    '')          continue ;;
  esac
  if [ "$section" = repos ]; then
    # name <TAB> org/repo <TAB> sha -- read splits on any whitespace run
    read -r nm slug sha _rest <<<"$line"
    [ -n "$nm" ] && [ -n "$slug" ] && [ -n "$sha" ] || die "versions.lock repos line not 'name slug sha': $line"
    case "$sha" in
      *[!0-9a-f]*) die "versions.lock: '$nm' sha is not hex: $sha" ;;
    esac
    [ "${#sha}" -eq 40 ] || die "versions.lock: '$nm' sha is ${#sha} chars, want a full 40"
    REPO_SLUG[$nm]="$slug"
    REPO_SHA[$nm]="$sha"
  elif [ "$section" = tooling ]; then
    case "$line" in
      *=*) k="${line%%=*}"; v="${line#*=}"; TOOL[$k]="$v" ;;
      *)   die "versions.lock tooling line not key=value: $line" ;;
    esac
  fi
done < "$lock"

[ "${#REPO_SHA[@]}" -eq 6 ] || die "expected 6 pinned repos, found ${#REPO_SHA[@]}"
for k in jdk17_url jdk17_sha256 jdk17_version jdk17_build jdk17_archive_root jdk17_dest \
         maven_url maven_sha512 maven_version maven_archive_root maven_dest \
         keycloak_url keycloak_sha256 keycloak_version node_major keycloak_java_major; do
  [ -n "${TOOL[$k]:-}" ] || die "versions.lock is missing tooling key '$k'"
done
ok "versions.lock parsed: ${#REPO_SHA[@]} repos, ${#TOOL[@]} tooling keys"

# --- shared helpers ---------------------------------------------------------
# Downloads land beside their destination, never in /tmp: /tmp on this box was
# wiped once and took an entire toolchain with it. The directory is created by
# fetch(), not here, so --check leaves no trace on disk.
dl_root="$root/runtime/downloads"

sha_of() { # <file> <sha256|sha512>
  case "$2" in
    sha256) sha256sum "$1" | cut -d' ' -f1 ;;
    sha512) sha512sum "$1" | cut -d' ' -f1 ;;
    *)      die "bad checksum algorithm '$2'" ;;
  esac
}

fetch() { # <url> <dest-path> <sha256|sha512> <expected>
  local url="$1" dest="$2" algo="$3" want="$4" have
  if [ "$CHECK_ONLY" -eq 1 ]; then die "missing $dest and --check was given" ; fi
  mkdir -p "$(dirname "$dest")"
  printf '  ...   downloading %s\n' "$(basename "$dest")"
  # -f so an HTML error page becomes a non-zero exit instead of a "tarball"
  # that explodes 200 lines into the log.
  curl -fSL --retry 3 --retry-delay 2 -o "$dest.part" "$url" \
    || die "download failed: $url"
  have="$(sha_of "$dest.part" "$algo")"
  if [ "$have" != "$want" ]; then
    rm -f "$dest.part"
    die "checksum mismatch for $(basename "$dest")
       expected $algo $want
       got              $have"
  fi
  mv "$dest.part" "$dest"
  ok "$(basename "$dest")  $algo ok"
}

# =============================================================================
step "1/4  upstream clones"
# =============================================================================
# The SHAs are re-verified here rather than trusted from bin/clone.sh, which
# exits 0 with "[x] already cloned" for a checkout at ANY commit. That makes it
# useless as the guard for a pin -- the one thing it is needed for.
for nm in "${!REPO_SHA[@]}"; do
  want="${REPO_SHA[$nm]}"
  dest="$root/repos/$nm"
  if [ -d "$dest/.git" ]; then
    have="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo unreadable)"
    if [ "$have" = "$want" ]; then
      ok "$nm  $want"
    else
      die "$nm is at $have but versions.lock pins $want
     A stale checkout is the failure this file exists to catch. Fix with:
       git -C repos/$nm fetch --depth 1 origin $want && git -C repos/$nm checkout $want
     or delete repos/$nm and re-run this script."
    fi
  else
    if [ "$CHECK_ONLY" -eq 1 ]; then
      missing "$nm  not cloned"
    else
      "$root/bin/clone.sh" "$nm" "${REPO_SLUG[$nm]}" "$want"
      have="$(git -C "$dest" rev-parse HEAD)"
      [ "$have" = "$want" ] || die "$nm: clone.sh reported OK but HEAD is $have"
    fi
  fi
done

# =============================================================================
step "1b/4  CDS-Library placement (CRD whole, PAS PriorAuth only)"
# =============================================================================
# Upstream builds do NOT create these directories; the library has to be copied
# into each service repo before bootRun, and the layout differs per service:
#   CRD: bootRun's CWD is CRD/server, and it walks CDS-Library/CRD-DTR from
#        there, so the WHOLE library goes at  repos/CRD/server/CDS-Library/
#   PAS: resolves CDS-Library/PriorAuth from its repo root, so ONLY the
#        PriorAuth subtree goes at  repos/prior-auth/CDS-Library/
# A missing placement is not detected by anything upstream: CRD boots and dies
# with "FATAL error: Failed to reload from folder: CDS-Library/CRD-DTR/ does
# not exist", PAS dies with a NullPointerException in populateRulesTable, and
# seed-valuesets.sh exits early. Pin-verified clones + this copy = rebuild.
SRC_LIB="$root/repos/CDS-Library"
[ -d "$SRC_LIB" ] || { missing "CDS-Library not cloned (step 1 ran before this?)"; }
CDS_OK="no"
if [ -d "$root/repos/CRD/server/CDS-Library/CRD-DTR" ] \
   && [ -d "$root/repos/prior-auth/CDS-Library/PriorAuth" ]; then
  CDS_OK="yes"
fi
if [ "$CDS_OK" = yes ]; then
  ok "CDS-Library placed (CRD whole @ repos/CRD/server, PAS PriorAuth @ repos/prior-auth)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  missing "CDS-Library not placed in the service repos (run provision.sh to copy)"
else
  cp -r "$SRC_LIB" "$root/repos/CRD/server/CDS-Library"
  mkdir -p "$root/repos/prior-auth/CDS-Library"
  cp -r "$SRC_LIB/PriorAuth" "$root/repos/prior-auth/CDS-Library/PriorAuth"
  ok "CDS-Library placed (CRD whole, PAS PriorAuth only)"
fi
unset SRC_LIB CDS_OK

# =============================================================================
step "2/4  JDK ${TOOL[jdk17_version]}+${TOOL[jdk17_build]}  ->  ${TOOL[jdk17_dest]}"
# =============================================================================
# Matched on IMPLEMENTOR_VERSION, not just JAVA_VERSION: upstream has both a
# 17.0.20+8 and a 17.0.20.1, so the version alone does not identify the build.
jdk_dest="$root/${TOOL[jdk17_dest]}"
if [ -x "$jdk_dest/bin/java" ]; then
  have="$(sed -n 's/^IMPLEMENTOR_VERSION="\(.*\)"$/\1/p' "$jdk_dest/release" 2>/dev/null || true)"
  if [ "$have" = "Temurin-${TOOL[jdk17_version]}+${TOOL[jdk17_build]}" ]; then
    ok "present  $have"
  else
    warn "present but is '$have', want 'Temurin-${TOOL[jdk17_version]}+${TOOL[jdk17_build]}'"
    if [ "$CHECK_ONLY" -eq 1 ]; then
      warn "ignored (--check)"
    else
      die "refusing to overwrite $jdk_dest automatically.
     Move it aside first, then re-run:
       mv $jdk_dest $jdk_dest.stale"
    fi
  fi
else
  if [ "$CHECK_ONLY" -eq 1 ]; then
    missing "not installed"
  else
    tgz="$dl_root/OpenJDK17U-jdk_x64_linux_hotspot_${TOOL[jdk17_version]}_${TOOL[jdk17_build]}.tar.gz"
    fetch "${TOOL[jdk17_url]}" "$tgz" sha256 "${TOOL[jdk17_sha256]}"
    # The archive's top-level directory is named for the build, not the version,
    # so it has to be moved into place rather than extracted where it lands.
    printf '  ...   extracting (slow on 9p, expect a minute)\n'
    tar -xzf "$tgz" -C "$dl_root"
    [ -d "$dl_root/${TOOL[jdk17_archive_root]}" ] \
      || die "archive did not contain ${TOOL[jdk17_archive_root]}"
    mv "$dl_root/${TOOL[jdk17_archive_root]}" "$jdk_dest"
    rm -f "$tgz"
    ok "installed  $("$jdk_dest/bin/java" -version 2>&1 | head -1)"
  fi
fi

# =============================================================================
step "3/4  Maven ${TOOL[maven_version]}  ->  ${TOOL[maven_dest]}"
# =============================================================================
# mvn -v needs java, but env.sh (which sets JAVA_HOME) is only sourced later at
# the Keycloak step, and on a fresh machine runtime/jdk17 only exists after the
# JDK step above. Point at it right here so both the version check and the
# installed line see a working java; same values env.sh exports.
export JAVA_HOME="$root/${TOOL[jdk17_dest]}"
export PATH="$JAVA_HOME/bin:$PATH"
mvn_dest="$root/${TOOL[maven_dest]}"
if [ -x "$mvn_dest/bin/mvn" ]; then
  have="$("$mvn_dest/bin/mvn" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ "$have" = "${TOOL[maven_version]}" ]; then
    ok "present  Apache Maven $have"
  else
    warn "present but reports $have, want ${TOOL[maven_version]}"
    [ "$CHECK_ONLY" -eq 1 ] || die "move $mvn_dest aside and re-run"
  fi
else
  if [ "$CHECK_ONLY" -eq 1 ]; then
    missing "not installed"
  else
    tgz="$dl_root/apache-maven-${TOOL[maven_version]}-bin.tar.gz"
    fetch "${TOOL[maven_url]}" "$tgz" sha512 "${TOOL[maven_sha512]}"
    tar -xzf "$tgz" -C "$dl_root"
    [ -d "$dl_root/${TOOL[maven_archive_root]}" ] \
      || die "archive did not contain ${TOOL[maven_archive_root]}"
    mv "$dl_root/${TOOL[maven_archive_root]}" "$mvn_dest"
    rm -f "$tgz"
    ok "installed  $("$mvn_dest/bin/mvn" -v 2>&1 | head -1)"
  fi
fi

# =============================================================================
step "4/4  Keycloak ${TOOL[keycloak_version]} + Node ${TOOL[node_major]} + JDK ${TOOL[keycloak_java_major]}"
# =============================================================================
# Keycloak goes to $KEYCLOAK_HOME, NOT under this folder: the zip is 177 MB and
# a small or slow volume. Sourced so the same default as bin/env.sh applies.
# shellcheck source=/dev/null
source "$root/bin/env.sh"

kc_dl="${KEYCLOAK_DOWNLOAD_DIR:-/opt/keycloak-downloads}"
kc_ver_file="$KEYCLOAK_HOME/version.txt"
if [ -f "$kc_ver_file" ]; then
  if grep -q "${TOOL[keycloak_version]}" "$kc_ver_file"; then
    ok "present  $(cat "$kc_ver_file")  at $KEYCLOAK_HOME"
  else
    warn "present but $(cat "$kc_ver_file"), want ${TOOL[keycloak_version]}"
    [ "$CHECK_ONLY" -eq 1 ] || die "move $KEYCLOAK_HOME aside and re-run"
  fi
else
  if [ "$CHECK_ONLY" -eq 1 ]; then
    missing "not installed at $KEYCLOAK_HOME"
  else
    mkdir -p "$kc_dl"
    zip="$kc_dl/keycloak-${TOOL[keycloak_version]}.zip"
    fetch "${TOOL[keycloak_url]}" "$zip" sha256 "${TOOL[keycloak_sha256]}"
    printf '  ...   extracting (ext4, fast)\n'
    # keycloak-<v>.zip contains a top-level keycloak-<v>/, so unzip into the
    # parent and rename rather than extracting straight onto $KEYCLOAK_HOME.
    unzip -q "$zip" -d "$kc_dl"
    [ -d "$kc_dl/keycloak-${TOOL[keycloak_version]}" ] \
      || die "zip did not contain keycloak-${TOOL[keycloak_version]}/"
    mv "$kc_dl/keycloak-${TOOL[keycloak_version]}" "$KEYCLOAK_HOME"
    rm -f "$zip"
    ok "installed  $(cat "$KEYCLOAK_HOME/version.txt" 2>/dev/null || echo '?')"
  fi
fi

# Node and JDK 21 are requirements rather than downloads: both are system-level
# installs here, and the JDK 21 in particular is an apt package that a
# self-extracting archive would be the wrong shape for. Asserted, not installed.
if command -v node >/dev/null 2>&1; then
  nhave="$(node --version | sed 's/^v//' | cut -d. -f1)"
  if [ "$nhave" = "${TOOL[node_major]}" ]; then
    ok "node $(node --version)"
  else
    die "node $(node --version) found, need major ${TOOL[node_major]}.
     dtr, crg and test-ehr all build with npm; the wrong major fails at webpack."
  fi
else
  die "node not found; need major ${TOOL[node_major]}"
fi

# kc.sh runs $JAVA_HOME/bin/java, and bin/env.sh points JAVA_HOME at JDK 17 --
# which is exactly why up.sh overrides it per-service. If the JDK 21 is missing
# that override has nothing to point at and Keycloak fails at start with a
# confusing "Unsupported class file" rather than a missing-JDK error.
if [ -x /usr/lib/jvm/java-${TOOL[keycloak_java_major]}-openjdk-amd64/bin/java ]; then
  ok "jdk ${TOOL[keycloak_java_major]}  $(
       /usr/lib/jvm/java-${TOOL[keycloak_java_major]}-openjdk-amd64/bin/java -version 2>&1 | head -1)"
else
  warn "no system JDK ${TOOL[keycloak_java_major]} at /usr/lib/jvm/java-${TOOL[keycloak_java_major]}-openjdk-amd64
     Keycloak will not start. Install it:
       apt-get install -y openjdk-${TOOL[keycloak_java_major]}-jdk-headless"
fi

printf '\n'
if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$MISSING" -gt 0 ]; then
    printf '\n%sprovision.sh --check: %d input(s) missing above.%s Run without --check to provision them.\n' \
      "$R" "$MISSING" "$N"
    exit 1
  fi
  printf '\n%sprovision.sh --check: all inputs present and pinned correctly.%s\n' "$G" "$N"
else
  printf '%sprovisioned.%s Next:\n' "$B" "$N"
  printf '  bin/up.sh            # 6 services, real readiness probes\n'
  printf '  bin/demo.sh          # 12 assertions\n'
  printf '  bin/e2e-browser.py   # 14 assertions, browser to a PAS decision\n'
fi
