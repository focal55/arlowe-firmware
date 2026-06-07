# Phase 3 staging harness

Runs the production Phase 3 install on the real dev Pi under a parallel
`arlowe-staging` user — side-by-side with the daily-driver setup, which it never
touches — to verify **SC4 sandbox write-deny against real systemd** and resolve
the speculative group / device questions from research §12. The Docker testbed
validated SC1–SC3 synthetically; this closes the real-hardware gap without a full
Phase 6 image build.

## Prerequisites

1. **SSH alias `arlowe-1`** with key-based auth (override with `ARLOWE_STAGING_HOST`).
2. **Stop the daily-driver face service first.** It holds the WhisPlay SPI/GPIO
   devices exclusively; if it's running, `07-hardware-speculative.sh` can't acquire
   the hardware and its gpiochip probe is inconclusive:

   ```bash
   ssh arlowe-1 "systemctl --user stop arlowe-face"
   ```

   Restart it after tear-down:

   ```bash
   ssh arlowe-1 "systemctl --user start arlowe-face"
   ```

## Run

From the repo root on the Mac:

```bash
bash tests/phase-3/staging/run-staging.sh
```

This syncs the repo to the Pi, installs the staging environment, runs SC1/SC2
(env-overridden), SC4, and the hardware probe, and captures output to
`.planning/phases/03-service-user-and-filesystem-layout/staging-observed-run.txt`.

## Tear down

Always tear down after reviewing — the harness does **not** auto-remove the
staging user:

```bash
ssh arlowe-1 'sudo bash /tmp/arlowe-firmware/scripts/provision/uninstall-arlowe-on-arlowe1-staging.sh'
ssh arlowe-1 'id arlowe-staging 2>&1'   # expect: no such user
```

## Output

Fold the observed-run results and the dialout/video/gpiochip decisions into
`docs/operations/phase-3-staging.md` (the permanent ops record) and the
`03-05-SUMMARY.md` Phase 3 closure document.
