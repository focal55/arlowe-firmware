# The image's package set, reproduced -- so SC4 is checked against what the device
# will actually have rather than against whatever the developer's machine carries.
#
# ARCHITECTURE. arm64 only, and not as a preference. python3-spidev and the lgpio
# packages the WhisPlay driver needs exist for arm64 bookworm and do not exist for
# amd64 at any version, so an amd64 run would have to stub them and the check would
# stop covering them.
# Build with --platform linux/arm64; tests/phase-07.1/run-import-check.sh does.
FROM debian:bookworm

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# apt layer, DERIVED from the real package list.
#
# The extraction below is character-for-character the one scripts/build-image.sh
# uses to feed pi-gen. Retyping the names here would create a second copy of the
# list to forget to update -- which is the defect class this phase exists to close,
# and would let this container go green against a package set the image does not
# have.
#
# ARLOWE_DROP_PACKAGES exists so the gate can be WATCHED FAILING: passing
# `--build-arg ARLOWE_DROP_PACKAGES=python3-pil` must make the check fail naming
# PIL under arlowe-face. It defaults to empty and dropping a package can only ever
# make the check stricter, never greener.
# ---------------------------------------------------------------------------
# The Raspberry Pi archive, because the image has it and this container exists to
# reproduce the image's package set. python3-lgpio and python3-rpi-lgpio -- the
# Pi 5 GPIO stack the WhisPlay driver imports as RPi.GPIO -- ship only here; Debian
# carries python3-rpi.gpio, whose 0.7.1 predates BCM2712 and cannot address a Pi 5.
# Without this source the derived set fails to install and the gate cannot run at
# all, which is not the same as the gate passing.
#
# Deliberately NOT pinned to a snapshot: this gate answers "does every import
# resolve against what the device has", and fidelity to the real archive is the
# point. Reproducibility of the package VERSIONS is a different gate's job
# (tests/phase-07.2/resolve-twice.sh), and pinning these is tracked in #146.
RUN echo "deb [trusted=yes] http://archive.raspberrypi.com/debian bookworm main" \
        > /etc/apt/sources.list.d/raspi.list

ARG ARLOWE_DROP_PACKAGES=""
COPY pi-gen/stage-arlowe/00-packages/00-packages-nr /tmp/00-packages-nr
RUN pkgs="$(sed 's/#.*//' /tmp/00-packages-nr | tr -s '[:space:]' '\n' | grep -v '^$')"; \
    for drop in ${ARLOWE_DROP_PACKAGES}; do \
        echo "### DELIBERATELY DROPPING ${drop} from the derived package set"; \
        pkgs="$(printf '%s\n' "${pkgs}" | grep -vxF "${drop}")"; \
    done; \
    echo "### derived package set:"; printf '  %s\n' ${pkgs}; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends ${pkgs}; \
    rm -rf /var/lib/apt/lists/*

# Test harness only. NOT part of the image's package contract -- the device never
# runs pytest, and adding these to 00-packages-nr would ship them. Kept in its own
# layer, after the derived one, so a reader can see exactly which packages came
# from the image list and which did not.
RUN apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends python3-pytest passwd; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# The arlowe user/group, from the real provisioning script.
#
# build-venvs.sh refuses to run without group `arlowe` (it chowns the venv tree
# root:arlowe), and install-arlowe-user.sh is the one thing in the repo that
# creates it. Its own header names the Phase 3 Docker testbed as a supported
# invocation, so this is the script running where it says it runs.
# ---------------------------------------------------------------------------
COPY scripts/provision/install-arlowe-user.sh /tmp/install-arlowe-user.sh
RUN bash /tmp/install-arlowe-user.sh

# ---------------------------------------------------------------------------
# The three venvs, built by the REAL builder at its REAL default path.
#
# build-venvs.sh resolves its requirement directory through one variable whose
# DEFAULT is the chroot path. Rather than override it, the files are staged at
# exactly that default, so what runs here is the same script reading the same path
# the image build reads -- no override is set, and build-venvs.sh is not modified
# by this plan at all. A forked venv recipe in this Dockerfile would let the CI job
# go green against a recipe the image does not use.
#
# ARLOWE_VENV_ROOT is likewise left at its default, so the interpreters land at
# /opt/arlowe/venvs/{voice,llm,stt}/bin/python -- the literal paths the units name.
# ---------------------------------------------------------------------------
ENV ARLOWE_CHROOT_REPO=/root/arlowe-build/repo
COPY pi-gen/stage-arlowe/01-runtime/files/ ${ARLOWE_CHROOT_REPO}/pi-gen/stage-arlowe/01-runtime/files/
RUN bash ${ARLOWE_CHROOT_REPO}/pi-gen/stage-arlowe/01-runtime/files/build-venvs.sh

# The repo itself is bind-mounted at run time, not copied: the checker reads the
# working tree, so a source edit must not need an image rebuild to be checked.
WORKDIR /repo
