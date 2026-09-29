# ADR-0011: Pairing setup channel — WPA2 setup hotspot, captive portal, optimistic handoff

<!-- status: accepted -->
**Status:** Accepted (owner decisions of 2026-09-28)
**Date:** 2026-09-28
**Phase:** 8 (First-boot pairing)
**Closes:** SC1's "mechanism decision recorded as an ADR"
**Hardware validation:** plan 08-27b

The values in this ADR are a contract. Later Phase 8 plans quote them verbatim. A value changes
here first, then in code.

## Context

A factory-fresh unit (no `/etc/arlowe/config.yml`) must get from the owner, with no app: home
Wi-Fi credentials, a dashboard password, a display name and a claim code. It then obtains its
device certificate and becomes reachable at `http://<name>.local:3000`.

What constrains the channel:

- **The unit has one radio.** The brcmfmac chip cannot hold an AP and test a station join at the
  same time in any way that keeps the owner's phone connected.
- **The Wi-Fi radio ships off.** pi-gen writes `WirelessEnabled=false` when `WPA_COUNTRY` is
  unset, and `raspberrypi-sys-mods` sets `rfkill default_state=0` (research N2).
- **`arlowe` is denied every NetworkManager action by default.** A systemd service has no polkit
  session, so the shipped policy's `allow_any` applies (research N3).
- **The six runtime units are enabled at build and run on an unpaired unit.** `arlowe-face` holds
  the Whisplay GPIO and the unauthenticated dashboard would face the setup network (research N1).
- **The factory image has no broker URL.** `identity.provisioning_url` is `""` and is never a
  tracked literal (research N11).
- **Secrets cross the setup link.** An open 802.11 network is sniffable by anyone in range, and
  WebCrypto is unavailable on `http://` origins, so the page cannot encrypt client-side (N8).

## Decision

### Channel

A NetworkManager access point plus an HTTP captive portal on `10.42.0.1:80`. No app.

### Hotspot security

WPA2-PSK: `wifi-sec.key-mgmt wpa-psk`, `wifi-sec.proto rsn`, `wifi-sec.pairwise ccmp`. The
password is generated fresh each time the unit enters pairing. It is shown as text on the
Whisplay and encoded in a `WIFI:T:WPA;S:<ssid>;P:<psk>;;` QR, so a camera scan joins it. It is
never logged and never persisted: the AP profile is created with `nmcli connection add save no`.

### Discretion values

| Item | Value |
|---|---|
| SSID | `Arlowe-Setup-<device_id[:4]>`, lowercase hex. All 65,536 suffixes were checked against the sanitize banlist; none produces a banned substring. |
| PSK | 12 characters from `23456789ABCDEFGHJKMNPQRSTUVWXYZ` via `secrets.choice`. No QR-special characters (`\ ; , : "`), so no escaping. |
| Wi-Fi country | `US`, a build constant: `ARLOWE_WIFI_COUNTRY` in `arlowe-radio-init.service`, plus `/etc/modprobe.d/arlowe-wifi-regdom.conf`. Not `raspi-config do_wifi_country`, which edits `cmdline.txt`, owned by `boot-config.sh`. A country picker is deferred; units sold outside the US need it. |
| AP radio and addressing | 2.4 GHz (`band bg`), channel 6, `ipv4.method shared`, `ipv4.addresses 10.42.0.1/24`, `ipv6.method disabled`. |
| Captive DNS | `/etc/NetworkManager/dnsmasq-shared.d/arlowe-captive.conf` = `address=/#/10.42.0.1`. NetworkManager passes that directory to the shared dnsmasq only if it exists, so the image ships it. |
| Idle timeout | 30 minutes with no successful submission: AP down, Whisplay shows "Press the button to start setup". A short press starts a new session with a new password. |
| NTP gate | No TLS call before `timedatectl show -p NTPSynchronized --value` prints `yes`, or 30 s have passed. |
| Portal binding | `10.42.0.1:80`, never `0.0.0.0`, so the portal is unreachable from a wired LAN. |

**Error kinds and owner strings** (identical on the Whisplay and the portal):

| Kind | String |
|---|---|
| `wifi_rejected` | "Wi-Fi password not accepted" |
| `wifi_not_found` | "Wi-Fi network not found" |
| `server_unreachable` | "Can't reach Arlowe servers" |
| `claim_rejected` | "Setup code not accepted" |
| `cert_failed` | "Couldn't get device certificate" |
| `not_configured` | "No setup server configured" |

The first five cover SC3's four failure modes. `wifi_rejected` and `wifi_not_found` come from
NetworkManager's state reason; the other identity failures map from
`arlowe-identity provision --json` (research N6), keeping its frozen exit codes:

| `provision --json` result | Kind |
|---|---|
| exit 4, `http_status` null | `server_unreachable` |
| exit 3, `http_status` 401 | `claim_rejected` |
| exit 3 with any other status; exit 4 with status >= 500; exit 5 | `cert_failed` |

**Broker URL supply.** `identity.provisioning_url` stays empty on the factory image. For dev and
the checkpoint, a FAT-partition file `/boot/firmware/arlowe-broker.json`
(`{"url": "...", "ca_bundle_pem": "..."}`) supplies it. Production supply waits on the AWS
decision (plan 07-09). With neither source, pairing shows `not_configured`. One resolver,
`runtime/lib/arlowe_broker.resolve_broker`, serves both pairing and reset's revoke (ADR-0013):
the FAT file first, its CA written to a private 0600 temp file and passed as
`ARLOWE_BROKER_CA_BUNDLE`; then `identity.provisioning_url` with system trust.

### Secrets never in argv

Every NetworkManager profile that needs a secret (the setup AP and the home join) is created
without it, then brought up with `nmcli connection up uuid <uuid> passwd-file /dev/stdin`, stdin
carrying `802-11-wireless-security.psk:<psk>`. The claim code reaches `arlowe-identity` through
`ARLOWE_OWNER_TOKEN` in the environment. The join profile is system-owned (`psk-flags 0`), so
NetworkManager persists the PSK it received for later boots; 08-27b confirms that on hardware.

- **Profiles are addressed by uuid.** The daemon generates a `uuid4`, passes it as
  `connection.uuid` at add time, and uses `uuid <uuid>` for `up` and `delete`, never the name.
  nmcli 1.42 reads a positional connection name through `next_arg`, which consumes
  `-a`/`--ask`/`-s`/`--show-secrets`-shaped words as global options, and an owner's SSID is
  untrusted input. Values after a property name in `connection add` are taken literally.
- **The passwd-file line is escaped for NetworkManager 1.42.4's parser**
  (`nmc_utils_parse_passwd_file` in `src/libnmc-base/nm-client-utils.c`; the image ships
  `network-manager 1.42.4-1+rpt1+deb12u1`). The parser strips the value's unescaped leading and
  trailing whitespace and treats `\` as an escape, so the daemon writes every `\` as `\\` and
  every space as `\ `, and rejects CR or LF before writing.
- **polkit `settings.modify.system` is load-bearing for PSK persistence.** Without it
  NetworkManager cannot write the system-owned join profile's secret, and the unit loses Wi-Fi at
  the next boot. Never trim it from the 51 rule.
- **Fallback if the AP profile will not take its PSK from passwd-file on hardware (08-27b SC1):**
  in-process libnm (`python3-gi` plus the `NM` typelib `gir1.2-nm-1.0`;
  `NM.Client.add_connection2` with the in-memory flag and the secret in the settings dict). The
  image ships `libnm0` but neither package today. The fallback is gated on verifying both, and
  `gir1.2-glib-2.0`, in the pinned snapshot, and it adds reference rows under the research N10
  merge gate. Never fall back to argv.

### Handoff

Optimistic. The form shows `http://<name>.local:3000` and the device IP before submit, because
the iOS captive sheet closes the moment the AP disappears. On submit the page answers, the AP
drops and the unit joins. On any failure the half-made profile is deleted, the AP returns with
the same session password, and the error shows on both surfaces. Submitted fields stay in memory
only. **Invariant: an unpaired unit has no saved Wi-Fi profile.**

### Commit point

The six runtime units carry `ConditionPathExists=/etc/arlowe/config.yml` and stay enabled at
build. Pairing writes, in order:

1. The owner credential and session key (ADR-0012).
2. The hostname, through the root oneshot `arlowe-pair-commit.service`.
3. `/etc/arlowe/config.yml`, atomically (tmp, validate, fsync, `os.replace`). **The commit point.**

Then, as the daemon's last act: draw the paired screen (URL and IP), hold it 30 s or until a
button press, release the Whisplay (`board.cleanup()`), `systemctl start --no-block` the six,
exit 0. A power cut leaves either "unpaired, pairing runs" or "paired, units run". A cut during
the hold is the second case.

### No `Conflicts=` between `arlowe-pair` and `arlowe-face`

Both are `WantedBy=multi-user.target`. `Condition*` is evaluated when a job runs, after the boot
transaction has already resolved a conflict in favour of the declaring unit, so
`Conflicts=arlowe-face.service` would cancel the face's start job on every boot of a paired unit.
The daemon hands the display over by exiting instead. (Research Pattern 1 proposed `Conflicts=`;
this supersedes it.)

### Setup-AP forwarding

`ipv4.method shared` enables IP forwarding and NAT from the setup AP to any other uplink, such as
a bench ethernet cable. `arlowe-radio-init` loads an nftables table every boot that drops
forwarded traffic entering or leaving `wlan0`. `nftables` is already in the rootfs, and the
appliance never routes, so the rule costs nothing once paired.

### Privilege split

`arlowe-pair.service` runs as `arlowe`. Root work happens in oneshots it starts through the
existing `arlowe-` polkit prefix:

- `arlowe-pair-commit.service`: hostname, the `127.0.1.1` line in `/etc/hosts`, avahi restart.
  It re-validates its input, because it is a privilege boundary.
- `arlowe-radio-init.service`, every boot: `rfkill unblock wlan`, `iw reg set`,
  `nmcli radio wifi on`, and the forwarding table above.

NetworkManager access comes from `provision/polkit/51-arlowe-networkmanager.rules`, granting
`arlowe` exactly `network-control`, `settings.modify.system`, `wifi.share.protected`,
`wifi.scan` and `enable-disable-wifi`. Research drafted `wifi.share.open`; a WPA2 AP needs
`wifi.share.protected` instead, and `wifi.share.open` is not granted.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| BLE provisioning | Needs a companion app or Web Bluetooth, and iOS browsers have no Web Bluetooth. Deferred with the companion app. |
| Open setup hotspot | The owner's first choice, reversed: the home PSK, dashboard password and claim code would cross the air in cleartext to anyone in range (research N8). The per-session WPA2 password keeps the camera-scan UX. |
| DHCP option 114 / RFC 8908 captive-portal API | The API must be served over HTTPS (RFC 8908 section 4). The unit has no publicly trusted certificate. |
| Validate-then-commit (test the join before dropping the AP) | A single radio cannot hold the AP while testing a join, and the owner's phone loses the portal either way. |
| `raspi-config do_wifi_country` | Edits `cmdline.txt`, which the A/B `boot-config.sh` owns. |
| Secrets in `nmcli` argv | Visible in `/proc/<pid>/cmdline` to every local user and in any process accounting. |
| `Conflicts=arlowe-face.service` on the pairing unit | Cancels the face's start job on every boot of a paired unit (see above). |

## Consequences

- SC1 has its ADR, and every pairing value has one source.
- A factory image cannot pair until a broker URL is supplied. Today that is the dev-only FAT file.
- Units sold outside the US need the deferred country picker before sale.
- The pairing daemon, not the face, owns the Whisplay until `config.yml` exists.

### Residual risks

- While pairing runs, the in-memory AP profile, with the per-session PSK, lives as a root-only
  0600 keyfile under `/run/NetworkManager/system-connections` (tmpfs; gone at reboot or
  `ap_down`).
- Android before 12 cannot resolve `.local`, so the paired screen shows the IP for its 30 s hold.
- The hashed hostname banlist lets someone confirm a guess of a banned literal.
- Anyone who can see the Whisplay can read the session password. Physical presence is the
  authorization for setup, as it is for the button reset.
