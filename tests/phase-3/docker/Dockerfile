FROM debian:bookworm-slim

# Install systemd as PID 1 plus tools needed for provisioning and tests.
# python3/python3-venv/nodejs/npm are present to match the production image contract;
# tests in this phase do not invoke them but later phases (SC3/SC4) will.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd \
      systemd-sysv \
      python3 \
      python3-venv \
      nodejs \
      npm \
      passwd \
      iproute2 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Create Pi OS-specific groups that the install script expects.
# On Pi OS, raspi-gpio and udev rules add gpio/spi/i2c groups for hardware access.
# debian:bookworm-slim does not include them; we add them here to keep the testbed
# behaviorally equivalent to a Pi OS bookworm environment.
RUN groupadd --system gpio && groupadd --system spi

# Remove getty units that cause systemd to spin on startup inside a container.
RUN rm -f /lib/systemd/system/getty@.service \
          /lib/systemd/system/console-getty.service \
          /etc/systemd/system/getty.target.wants/getty@tty1.service \
 && systemctl disable --no-reload \
      systemd-networkd-wait-online.service 2>/dev/null || true

# Mask units that cause unnecessary noise or failures inside a privileged container.
RUN systemctl mask \
      systemd-firstboot.service \
      systemd-udevd.service \
      systemd-modules-load.service \
      apt-daily.service \
      apt-daily-upgrade.service \
      e2scrub_reap.service 2>/dev/null || true

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/sbin/init"]
