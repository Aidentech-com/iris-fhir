# Security Policy

## Scope: read this first

This repository is **a demonstration of an unauthenticated healthcare workflow**. When it is
running, six ports are bound to `0.0.0.0` and it will accept, adjudicate and record a prior
authorization claim from anything that can reach it. The PAS runs with `BYPASS_AUTH=true`. The
Keycloak realm uses the published credentials `admin`/`admin` and `dtr`/`dtr-demo`, and a
client secret of `#replaceMe#`.

**Please do not report these.** They are not findings, they are the documented design; see the
Security note in [`README.md`](README.md). A report that consists of "the demo credentials are
published" or "PAS does not check auth" will be closed without further review.

Also out of scope, and not this repository's to fix:

- anything in the six upstream HL7 DaVinci projects. If you find a vulnerability there, report
  it to that project. Where a credential is hardcoded in an upstream project, this repository
  deliberately redacts the value and documents only the *finding*.
- the published demo credentials themselves, as reused *elsewhere*. If you have found the same
  password in a different, real system, that is a report about that system, not this one.

## In scope

- a credential, token, private key or real patient data committed to **this** repository
- a host identifier, personal path or personal email address that should not be published
- a bug in `bin/` that would run something destructive, or lose data, without being asked
- an issue in `versions.lock` or `bin/provision.sh` that would install or build something other
  than the pinned artefacts

## How to report

**Do not open a public issue.** Use GitHub's private vulnerability reporting
("Security" → "Report a vulnerability"), or email the repository owner directly. Include the
commit SHA, the file, and the steps to reproduce.

You should get an acknowledgement within a few days.

## What to do if you have already leaked a real credential here

A force-push is not enough. GitHub continues to serve unreachable objects by SHA, so a rewrite
removes the reference without removing the content:

```bash
# after the rewrite, the OLD commit is still fetchable by SHA, with no ref pointing at it
git fetch origin <old-sha>
git cat-file -p <old-sha>:path/to/file    # still there
```

The only reliable remedies are deleting and recreating the repository, or asking GitHub Support
to purge the unreachable objects. Ask, and say plainly that a rewrite has already been done and
the object is still retrievable by SHA.
