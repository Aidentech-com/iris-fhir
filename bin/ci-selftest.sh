#!/usr/bin/env bash
#
# Prove the CI guards can actually fail.
#
# WHY THIS EXISTS
#
# A guard that has only ever passed is indistinguishable from a guard that is
# broken. Four of the twelve steps in ci.yml were in exactly that state when
# this repository was first pushed, and the failure emails that followed were
# the only evidence:
#
#   1. The upstream-credential guard matched its own source line. The tree
#      contained no credential. The pattern spelled the variable in plain text
#      and the character after the quote in that file is "[", which is neither
#      a quote nor a "<", so the guard rejected itself.
#   2. Writing the explanation of (1) into the same file reproduced the
#      literal a second time, and the guard rejected itself again.
#   3. The private-repo guard could never fire. It read
#      `the repo(itory)? is \*\*private`, and "repository" leaves "sitory"
#      after "repo" -- the optional group was missing its leading "s". One
#      character, and the guard cheerfully passed on the exact sentence it was
#      written to reject.
#   4. Five grep guards were written as `if grep ...; then fail; fi`. grep
#      exits 2 when it cannot read the tree, and `if` treats 2 like 1, so a
#      scan that never ran reported success.
#
# Three of those were self-inflicted by the act of documenting the first. The
# common cause is not carelessness; it is that each guard was tested against
# the strings it was supposed to catch rather than against the directory it
# scans, which contains itself. This script performs that missing test.
#
# Each case plants one leak and asserts that exactly the intended step fails.
# It runs entirely inside a throwaway snapshot, so the working tree is never
# modified and cannot be left dirty.
#
# USAGE
#   ./bin/ci-selftest.sh
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/.ci-local/selftest"

command -v python3 >/dev/null || { echo "need python3" >&2; exit 2; }
rm -rf "$ROOT/.ci-local"
mkdir -p "$SCRATCH"

# Snapshot: working-tree files minus the heavy gitignored dirs, plus .git so
# that the guards which shell out to git behave as they will on the runner.
tar -C "$ROOT" -cf - \
  --exclude=./.git --exclude=./repos --exclude=./runtime \
  --exclude=./.ci-local --exclude=./node_modules --exclude=./logs . \
  | tar -C "$SCRATCH" -xf -
cp -a "$ROOT/.git" "$SCRATCH/.git"

cd "$SCRATCH"
mkdir -p .ci-local/steps

python3 - .github/workflows/ci.yml .ci-local/steps <<'PY'
import sys, yaml, pathlib, re
wf, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
steps = yaml.safe_load(wf.read_text())['jobs']['verify']['steps']
n = 0
for s in steps:
    if 'run' not in s:
        continue
    n += 1
    name = re.sub(r'[^A-Za-z0-9]+', '-', s.get('name', f'step-{n}')).strip('-')
    (out / f'{n:02d}-{name}.sh').write_text(s['run'])
PY

# step-key | file to plant into | text to plant
#
# "@@" is a join marker, removed before the text is written. It exists because
# the guards in ci.yml scan the whole tracked tree, this file is tracked, and
# the first version of this table spelled the plants out in full. The suite
# then failed cleanly -- on a repository containing no secret, no IP and no
# upstream token -- because the test data was the only match. "@@" cannot occur
# in any guarded pattern: every one of them requires specific literal
# characters at that position, and "@@" is not among them. Splitting the
# literals is the same trick the guards use on themselves, applied to their own
# test data. It is the fifth appearance of this lesson, which is why it is
# recorded here instead of being left as a curiosity.
#
# The split must cover the VALUE as well as the name. An earlier version of this
# table protected "ADMIN_TOKEN" with "@@" but spelled the upstream token value
# out in full, on the reasoning that guard 8 matched the name-and-quote shape and
# would never see a bare value. That reasoning was wrong, and the consequence
# was that the token was published in this file -- in a repository whose entire
# reason for existing publicly is that it does not contain it. Guard 8 now
# matches the obfuscated value directly, there are cases below for a bare value
# with no name attached, and the lesson generalises: a guard written as a shape
# is only as good as the shapes you thought to enumerate. Matching the secret
# itself is the version that does not need that list.
#
# "!!" is a delete marker, and it exists for the same reason: not every guard
# has a "bad thing was added" failure mode. The guard that the non-root install
# paths are documented fails when a line is *absent*, so proving it sensitive
# requires removing one, and appending text cannot do that. The rest of the
# marker is deleted as a fixed string, not a regex -- the file names a specific
# line, and a regex here would be one more thing that can be subtly wrong.
#
# The step keys are substrings of the step filenames. Each text is chosen to be
# something a real contributor could plausibly commit.
CASES=$(cat <<'EOF'
06-No-secrets|README.md|Here is my key: ghp_@@ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
06-No-secrets|README.md|aws key AKIA@@IOSFODNN7EXAMPLE here
07-No-host|README.md|The runner was at 10@@.9.9.9 when this happened.
07-No-host|README.md|Scratch space lives at /tmp/@@sandbox-01/run-1
08-No-upstream|README.md|ADMIN_@@TOKEN = "Y3YW@@q2l08kvFqy50fQJY"
08-No-upstream|SOURCES.md|Upstream ships ADMIN_@@TOKEN = "s3cr3t-@@upstream-value"
08-No-upstream|README.md|The value is Y3YW@@q2l08kvFqy50fQJY, unlabelled
11-Documentation|README.md|```\nunterminated fence
12-Documentation|README.md|The repository is **@@private**", so git clone needs credentials
12-Documentation|README.md|The repo is **@@private**" and should stay that way while the stack exists.
13-The-non-root|README.md|!!export VSAC_CACHE_DIR=
EOF
)

pass=0; fail=0
printf '\n  %-58s %s\n' "planted" "result"
printf '  %-58s %s\n' "----------------------------------------------------------" "------"

# The scratch tree arrives carrying whatever the real working tree had in
# progress, so "must be clean at the end" is the wrong test -- it would report
# the author's uncommitted work as residue. Compare against the baseline
# instead: a case that fails to restore is a case that can mask the next one.
#
# Restoring the baseline, though, cannot be done with `git checkout --`. That
# restores from the INDEX, not from the working tree, so in a scratch tree
# carrying uncommitted changes it silently discards them: the first version of
# this loop used it, and the very first run against a working tree with an
# uncommitted README reported "planting changed the scratch tree" for a file no
# case had touched, because restoring "clean" meant restoring the committed
# version. The stated intent above and the mechanism below it did not agree.
#
# So: snapshot the file once, before the first case that touches it, and copy it
# back afterwards. That restores the tree to exactly what the loop found,
# whatever state git thinks that is.
mkdir -p .ci-local/orig
snapshot() {
  local f="$1" slot
  slot=".ci-local/orig/$(printf '%s' "$f" | tr '/' '_')"
  [ -e "$slot" ] || cp -a "$f" "$slot"
}
restore() { cp -a ".ci-local/orig/$(printf '%s' "$1" | tr '/' '_')" "$1"; }

# Apply a plant. "!!<fixed string>" deletes every line containing it, which is
# how a guard with an "absent" failure mode is made to fail at all.
plant() {
  local f="$1" text="$2"
  if [ "${text:0:2}" = '!!' ]; then
    python3 -c '
import sys, pathlib
path, needle = pathlib.Path(sys.argv[1]), sys.argv[2]
kept = [l for l in path.read_text().splitlines(keepends=True) if needle not in l]
path.write_text("".join(kept))
' "$f" "${text:2}"
  else
    # A file that does not end in a newline would glue the planted text onto its
    # last line. The fence-balance guard counts on the plant becoming its own
    # line, and glued text also changes what a would-be commit looks like, so
    # separate the plant the same way an editor would.
    [ -z "$(tail -c 1 "$f")" ] || printf '\n' >> "$f"
    printf '%b\n' "${text//@@/}" >> "$f"
  fi
}

git status --porcelain | sort > .ci-local/baseline.txt

while IFS='|' read -r key file text; do
  [ -n "$key" ] || continue
  target=$(ls .ci-local/steps/ | grep -m1 "$key" || true)
  if [ -z "$target" ]; then
    printf '  %-58s %s\n' "${text:0:56}" "NO SUCH STEP ($key)"
    fail=$((fail + 1)); continue
  fi

  snapshot "$file"
  plant "$file" "$text"

  if bash -e ".ci-local/steps/$target" >/dev/null 2>&1; then
    printf '  %-58s %s\n' "${text:0:56}" "DID NOT FIRE  <-- vacuous"
    fail=$((fail + 1))
  else
    printf '  %-58s %s\n' "${text:0:56}" "caught by ${target%%.*}"
    pass=$((pass + 1))
  fi
  restore "$file"
done <<< "$CASES"

echo
printf '  %d of %d planted leaks were caught\n' "$pass" "$((pass + fail))"

# A case that failed mid-loop can leave its plant behind, which would then make
# a later case pass for the wrong reason. Diff against the baseline, not
# against an assumed-clean tree.
git status --porcelain | sort > .ci-local/after.txt
if diff -u .ci-local/baseline.txt .ci-local/after.txt > .ci-local/residue.txt; then
  echo "  scratch tree restored to its baseline, nothing left behind"
else
  echo "  ::error::planting changed the scratch tree:"
  sed 's/^/    /' .ci-local/residue.txt | head -20
  fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] || { echo; echo "  $fail problem(s)"; exit 1; }
echo "  every guard is sensitive"
