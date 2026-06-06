# Phase 3 test harness

Validates SC1 (user shape) and SC2 (filesystem layout) for the arlowe service user
provisioning. The Docker testbed is the primary gate; hardware-loop validation is
owned by plan 03-05.

## Quickstart

```bash
# From the repo root:
bash tests/phase-3/docker/run-tests.sh
```

Docker must be running and the repo root must be accessible. The harness builds the
`arlowe-phase3-testbed` image on first run (debian:bookworm-slim + systemd), then
executes the install scripts and assertion scripts inside a privileged container.

## Env-var override for staging harness (plan 03-05)

The assertion scripts are fully parameterized. Setting `ARLOWE_USER=arlowe-staging`
re-targets every assertion at the staging tree without editing any script:

```bash
ARLOWE_USER=arlowe-staging bash tests/phase-3/assertions/01-user-shape.sh
ARLOWE_USER=arlowe-staging bash tests/phase-3/assertions/02-fs-layout.sh
```

This is the exact contract plan 03-05's staging harness consumes. The derived vars
(`ARLOWE_GROUP`, `ARLOWE_HOME`, `ARLOWE_OPT`, `ARLOWE_ETC`) all default from
`ARLOWE_USER`, so a single export is typically sufficient.

## Debugging a failed run

Leave the container running for interactive inspection:

```bash
PHASE_3_TESTBED_KEEP=1 bash tests/phase-3/docker/run-tests.sh
# Follow the printed container ID, then:
docker exec -it <container_id> bash
```

## Assertion script reference

| Script | SC | Install script likely missing | What it checks |
|---|---|---|---|
| `01-user-shape.sh` | SC1 | `install-arlowe-user.sh` | uid < 1000, HOME, shell=/usr/sbin/nologin, no founder user, supplementary groups |
| `02-fs-layout.sh` | SC2 | `install-arlowe-fs.sh` | ownership + mode of every path in the layout table; config.yml and defaults.yml absent |

## What the Docker testbed does NOT validate

- **SC3** (systemd unit syntax + security scores) — plan 03-02 owns unit files.
- **SC4** (sandbox write denial on real hardware) — requires SPI/GPIO/ALSA devices.
- **Hardware-loop validation** — plan 03-05 runs assertions against a live
  `arlowe-staging` user on the dev Pi, confirming gpio/spi/audio group access
  against real Pi kernel devices.

Hardware-loop validation (SC4 negative-write on a real Pi) is owned by plan 03-05,
not this Docker testbed.
