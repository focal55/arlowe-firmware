#!/bin/bash
# Host-side stage entry for stage-arlowe.
# pi-gen calls this before entering the sub-stages. No-op at this level —
# all provisioning happens in 01-runtime/00-run.sh (host staging) and
# 01-runtime/00-run-chroot.sh (chroot provisioning).
set -euo pipefail
