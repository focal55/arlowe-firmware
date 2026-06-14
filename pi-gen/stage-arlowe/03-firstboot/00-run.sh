#!/bin/bash
# Host-side step: nothing to do here — the first-boot service and its script
# are installed into the chroot by 00-run-chroot.sh in this sub-stage.
# pi-gen runs host-side 00-run.sh before 00-run-chroot.sh, so this file is a
# required placeholder to satisfy pi-gen's stage convention.
set -euo pipefail
