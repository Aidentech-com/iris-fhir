name: Something is broken
description: The stack fails to install, start, or one of the drivers fails.
about: Please do not read the security note first — if your finding is "the demo credentials are published" or "PAS does not check auth", that is the design. See SECURITY.md.
title: ''
labels: bug
assignees: ''

## What happened

<!-- Paste the actual error text. "It doesn't work" is not diagnosable. -->

```

```

## What you expected

## Which step

- [ ] `bin/provision.sh`
- [ ] `bin/provision.sh --check`
- [ ] `bin/up.sh`
- [ ] `bin/demo.sh`
- [ ] `bin/e2e-browser.py`
- [ ] the browser at http://localhost:3001/

## Environment

Paste the output of:

```bash
. /etc/os-release; echo "$PRETTY_NAME"
node --version
java -version 2>&1 | head -1
python3 --version
git --version
df -h . | tail -1
free -h | head -2
./bin/provision.sh --check 2>&1 | tail -20
```

## Already tried

<!-- If you read the accompanying runbook notes, say which part. They usually have the answer. -->

## Anything that would help reproduce

<!-- Service logs are in logs/, one per service. Paste the relevant lines. -->
