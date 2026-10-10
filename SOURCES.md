# Sources

Every claim in this documentation traces to one of these. Access date: **2026-09-26**.

---

## The setup document

| | |
|---|---|
| Title | Setting up CRD, DTR and PAS Reference Implementations (RIs) |
| URL | https://chat.fhir.org/user_uploads/10155/MD566nzochvz2rIbEd48QCEh/Setting-up-CRD_DTR_PAS-2.pdf |
| Format | PDF 1.7, 8 pages, 7,111 non-whitespace chars of text |
| Screenshots | 8 embedded images, pages 2, 3, 4, 5, 6 (×2), 7 (×2) — pixels, not extractable |

Full text extracted to `/tmp/davinci-scratch/crd_dtr_pas.txt` (211 lines) via `pdftotext -layout`.
Per-page character counts confirm no page is empty:

```
page 1: 1443    page 4:  769    page 7:  681
page 2:  912    page 5: 1075    page 8:  464
page 3: 1202    page 6:  565
```

The screenshots carry no load-bearing information beyond the adjacent prose, which describes
their content ("You should see a screen similar to the one below", "the left panel will update
automatically").

---

## The bug reference

**Location:** `DockerLocalSetupGuide.md` line **311 of 313**, repo root of `HL7-DaVinci/prior-auth`.

- Commit-pinned permalink:
  https://github.com/HL7-DaVinci/prior-auth/blob/281cadc106e2/DockerLocalSetupGuide.md#L311
- Branch permalink:
  https://github.com/HL7-DaVinci/prior-auth/blob/master/DockerLocalSetupGuide.md#L311
- Raw: https://raw.githubusercontent.com/HL7-DaVinci/prior-auth/master/DockerLocalSetupGuide.md

The text, with the line above it:

```markdown
310: <!-- 12. Submit PAS Request to http://localhost:9015/fhir   -->
311: 12. Submit PAS Request to https://davinci-prior-auth.logicahealth.org/fhir (submitting request locally has a bug and is being worked on)
```

The original local target is preserved one line up in an HTML comment. It is the **only**
occurrence of "bug" in the document, and it carries no issue link, ticket number, or owner.

### Commit history for that file

```
281cadc106e2  2022-05-04T17:07:20Z  | updates to read me instructions
4a3afe508c16  2022-05-03T17:57:18Z  | Update DockerLocalSetupGuide.md
3788034a48c6  2022-05-03T17:47:50Z  | spelling corrections
```

Queried via `https://api.github.com/repos/HL7-DaVinci/prior-auth/commits?path=DockerLocalSetupGuide.md`

Last modified **2022-05-04**. The repo itself was pushed **2026-07-22**. As of 2026-09-26 that
makes the note **4 years 4 months** stale. Either the fix landed and the doc was never reverted,
or it was abandoned. Phase 0 distinguishes them.

---

## Repositories

All five alive, none archived. `test-ehr` is described upstream as "a simple HAPI FHIR server
based on the hapi-fhir-jpaserver-example with additions to support CRD and DTR".

**Pinned SHAs, resolved 2026-09-26.** These are what the native bring-up clones. Note the repo is
`HL7-DaVinci/dtr` — **`hlseven/davinci-dtr` 404s** despite being cited in the PDF and in several
upstream docs.

| Repo | Pinned SHA (master) | Date | Lang | Build | Evidence |
|---|---|---|---|---|---|
| [`HL7-DaVinci/prior-auth`](https://github.com/HL7-DaVinci/prior-auth) | `848f28c11d8efb4e253b70cfbbc485acf9acd1a0` | 2026-07-22 | Java | Gradle 8.14.2 wrapper | **BOOT** |
| [`HL7-DaVinci/CRD`](https://github.com/HL7-DaVinci/CRD) | `43547c4e69052df4d3532972e4bd03f8d5317d13` | 2026-07-21 | Java | Gradle wrapper | READ |
| [`HL7-DaVinci/dtr`](https://github.com/HL7-DaVinci/dtr) | `7acf79a6f89bfe9e88c30e9d4b531f647ce09c41` | 2026-07-22 | JavaScript | `npm start` | READ |
| [`HL7-DaVinci/crd-request-generator`](https://github.com/HL7-DaVinci/crd-request-generator) | `87e98bf9af4fb528b624171edbe702880e325c59` | 2026-01-12 | JavaScript | `npm start` | READ |
| [`HL7-DaVinci/test-ehr`](https://github.com/HL7-DaVinci/test-ehr) | `e3f07ce4d81063e99e475cccaedba93becb8ef1d` | 2025-09-18 | Java | **Maven, no wrapper** | READ |

**Mixed build tooling is the first thing to internalise:** Gradle for CRD + PAS, Maven for
test-ehr, npm for dtr + crd-request-generator. `dtr` is `"type": "module"` (ESM) with a
`node ./bin/prod` backend — it is *not* a JVM service, and it declares no `engines` field, so
nothing self-documents its Node requirement.

**Dropped:** keycloak (see the Keycloak section below — retired 2026-09-26).


---

## Containerization assets present on `master`

| Repo | Container files | CI |
|---|---|---|
| CRD | `Dockerfile`, `Dockerfile.dev`, `dockerRunnerDev.sh`, `server/src/main/resources/application-docker.yml` | `automated-tests-ci.yml`, `docker-ci.yml` |
| prior-auth | `Dockerfile`, `Dockerfile.dev`, `Dockerfile.porter-windows`, `Dockerfile.tmpl`, `docker-compose.yml`, `docker-compose-dev.yml`, `docker-compose-porter.yml`, `docker-sync.yml`, `dockerRunnerDev.sh`, `porter.yaml`, 2 setup guides | 8 workflows incl. `docker-ci.yml`, `docker-cd.yml`, `porter-*.yml` |
| dtr | `Dockerfile`, `Dockerfile.dev`, `docker-compose.yml`, `dockerRunnerDev.sh` | **Drone only** (`.drone.yml`) — no `.github/` at all |
| crd-request-generator | `Dockerfile` | `docker-ci.yml`, `docker-cd.yml` |
| test-ehr | `Dockerfile`, `.dockerignore` | `maven.yml`, `smoke-tests.yml` |

### The 9 services in `prior-auth/docker-compose.yml`

`version: '3.6'`. Every service uses a prebuilt image — **not one `build:` key**. No `depends_on`,
no `healthcheck`, no `networks:`, no `restart:`.

| # | service | image | ports | key env |
|---|---|---|---|---|
| 1 | keycloak | `smalho01234/keycloak` | 8180:8080 | `KEYCLOAK_IMPORT=/resources/ClientFhirServerRealm.json` |
| 2 | test-ehr | `smalho01234/test-ehr` | 8080:8080 | `DOCKER_PROFILE=true` |
| 3 | crd | `smalho01234/crd2` | 8090:8090 | `VSAC_API_KEY: ${VSAC_API_KEY}` |
| 4 | crd-request-generator | `smalho01234/crd-request-generator` | 3000, 3001 | — |
| 5 | dtr | `smalho01234/dtr` | 3005:3005 | — |
| 6 | prior-auth | `smalho01234/prior-auth` | 9015:9015 | `TOKEN_BASE_URI=http://localhost:9015` |
| 7 | prior-auth-client | `smalho01234/prior-auth-client` | 9090:9090 | — |
| 8 | fhir-x12 | `smalho01234/fhir-x12` | 8085:8085 | `ADMIN_TOKEN=<image default>` |
| 9 | fhir-x12-frontend | `smalho01234/fhir-x12-frontend` | 3015:3015 | `BACKEND_URL=http://localhost:8085/` |

Image provenance problem: all untagged `latest` under a personal Docker Hub account
`smalho01234`, and `docker-cd.yml` fires on push to **`dev`** — so `prior-auth:latest` is built
from `dev`, not the `master` being read. A second, divergent pipeline (`.drone.yml`) publishes to
`hlseven/davinci-prior-auth` on `master`.

`docker-compose-porter.yml` is a byte-for-byte clone with `container_name` prefixes changed
`pas_prod_` → `pas_porter_`. `Dockerfile.tmpl` has every functional line commented out, leaving
`FROM ubuntu:latest` plus three COPYs — Porter is purely a UX wrapper for
`porter install fullstack_drls_pas`, adding no dependency ordering or reproducibility.

The only properly published image found: **`hlseven/davinci-dtr:latest`** (Drone, multi-arch
amd64/arm64, on every master merge). `dtr`'s readme still references a stale personal namespace
`hspc/davinci-dtr`.

---

## Key version evidence

| Source | Says |
|---|---|
| `prior-auth/Dockerfile` | `FROM amazoncorretto:17-alpine-jdk` — Java 17 |
| `prior-auth/gradle/wrapper/gradle-wrapper.properties` | Gradle **8.14.2** |
| `prior-auth/Dockerfile.dev` | `gradle:6.9.0-jdk11` — stale vs wrapper |
| `prior-auth/.github/workflows/automated-tests-ci.yml` | java 11 / gradle 6.9 — stale |
| `prior-auth/build.gradle` | spring-boot 2.7.18, hapiFhir 8.2.1, cql-engine 1.3.12.1 |
| `dtr/Dockerfile` | `node:22-alpine` (both stages) |
| `crd-request-generator/Dockerfile` | `node:22-alpine` (both stages) |
| `crd-request-generator/README.md` | "tested with Node 22" |

Neither Node `package.json` has an `engines` field, so Node 12 fails with opaque ESM errors
rather than a clear message.

The Keycloak version is inferred from the compose volume path
`/opt/jboss/keycloak/standalone/data/` and the `KEYCLOAK_IMPORT` env var (a custom-image
convention, not stock Keycloak) — both are pre-Quarkus, i.e. **≤16.x**.

> **Keycloak is retired from the stack (2026-09-26).** Recorded for completeness, and because the
> "0 users in the realm" finding that first flagged it turned out to be a red herring.
>
> Nothing in the 5-service stack consumes a Keycloak token:
>
> | Service | Config | Value |
> |---|---|---|
> | test-ehr | `src/main/resources/application.yaml:88` | `use_oauth: false` |
> | crd | `server/src/main/resources/application.yml:34` | `checkJwt: false` |
> | prior-auth | own `/auth/register` + `/auth/token` over an H2 `Client` table | — |
>
> Had it stayed, it would have been the worst native citizen available: the compose image is
> WildFly-based, `keycloak-server-dist:4.8.3` is **404** on Maven Central, **6.0.1 is the last
> WildFly dist** (verified HTTP 200) and it needs **Java 8** — a second JDK tarball for an EOL
> runtime. The realm JSON's own `keycloakVersion` field says `15.0.2`, which is Quarkus-era, so the
> upstream image and the shipped realm do not even agree. It also would have forced the
> "add `alice`/`alice`" manual step, which is now unnecessary.


---

## `ClientFhirServerRealm.json`

https://raw.githubusercontent.com/HL7-DaVinci/test-ehr/master/src/main/resources/ClientFhirServerRealm.json

Realm `ClientFhirServer`. **9 clients, 0 users.**

| clientId | public | bearerOnly | redirect URIs | webOrigins |
|---|---|---|---|---|
| `account` | no | no | `/realms/ClientFhirServer/account/*` | — |
| `account-console` | yes | no | `/realms/ClientFhirServer/account/*` | — |
| `admin-cli` | yes | no | — | — |
| **`app-login`** | **yes** | no | **`http://localhost:8080/*`** | `*` |
| `app-signed-jwt` | no | yes | — | — |
| `app-token` | no | yes | `localhost:8080` | `*` |
| `broker` | no | no | — | — |
| `realm-management` | no | yes | — | — |
| `security-admin-console` | yes | no | `/admin/ClientFhirServer/console/*` | `+` |

Two consequences: the `alice` user must be created by hand (fix #14), and `app-login`'s redirect
URI is `localhost:8080`-rooted — fine for a same-host demo, broken for any other origin.

---

## Standards context

- Da Vinci background: https://hl7.org/fhir/us/davinci-crd/STU1/background.html — confirms CRD,
  DTR and PAS are **payer-side**. The provider/EHR side is a separate concern; the Da Vinci
  `test-ehr` is a stand-in FHIR server, not an HIS.
- CRD supported hooks: http://hl7.org/fhir/us/davinci-crd/en/hooks.html — six hooks at
  `/r4/cds-services`: `appointment-book`, `encounter-start`, `encounter-discharge`,
  `order-dispatch`, `order-select`, `order-sign`.
- CDS Hooks spec: https://cds-hooks.github.io/ — `CDS Client` is the EHR-side component; confirms
  the doc contains no client-side HIS.

---

## Files retrieved during investigation

| Path | Purpose |
|---|---|
| `/tmp/davinci-scratch/crd_dtr_pas.pdf` | the setup document |
| `/tmp/davinci-scratch/crd_dtr_pas.txt` | full text extraction, 211 lines |
| `/tmp/davinci-scratch/dlsg.md` | `DockerLocalSetupGuide.md`, used to locate line 311 |
| `/tmp/davinci-scratch/realm.json` | `ClientFhirServerRealm.json`, parsed for the client table |

Note: `/tmp` is ephemeral. Re-fetch from the URLs above if these are needed later.

---

## Toolchain availability — verified 2026-09-26

| Tool | Result | Note |
|---|---|---|
| docker / podman / nerdctl / buildah | **absent** | and not wanted — the stack runs as native processes |
| system Java | 21 | too new for some upstream builds |
| Temurin JDK 17.0.20.1 | ✅ `api.adoptium.net` HTTP 200 | unpacked to `/tmp/davinci-scratch/jdk17`; **non-invasive by design** |
| Temurin JDK 8 | HTTP 200 | only needed if legacy Keycloak returns — it does not |
| system Gradle | **4.4.1** | fails on `build.gradle:6` `allowInsecureProtocol`; use the 8.14.2 wrapper |
| Node | **22.23.1**, npm 10.9.8 | present; satisfies dtr + crd-request-generator |
| `mvn` | **absent** | test-ehr ships a `pom.xml` and **no `mvnw`** |
| Apache Maven 3.9.9 tarball | HTTP 200 | the one download still needed |
| `keycloak-server-dist` 4.8.3 | **404** | 6.0.1 → HTTP 200 (last WildFly dist) |
| Host arch | `x86_64` | legacy-Keycloak arm64 concern was moot |
| RAM | 7 GB total, **~3 GB available** | the binding constraint on heap sizing |

