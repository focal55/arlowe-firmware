# Phase 8 pairing, reset and hardware-checkpoint runbook

**Status:** Reviewed script for the Phase 8 hardware checkpoint. No step here has run on
hardware yet; the checkpoint fills in the evidence template at the end and corrects any step
the hardware contradicts.

The values quoted here (SSID, error strings, unit names, ledger paths) come from
[ADR-0011](../architecture/0011-pairing-setup-channel.md) (setup channel),
[ADR-0012](../architecture/0012-owner-credential-and-claim-codes.md) (password and claim codes)
and [ADR-0013](../architecture/0013-factory-reset.md) (reset). Where this runbook and an ADR
disagree, the ADR wins.

Roles: **the dev machine** runs the local broker and flashes cards; **the build host** is the
arm64 Linux machine that builds the image; **the unit** is the Pi under test. Examples use
documentation addresses: the dev machine is `192.0.2.10`, the unit is `192.0.2.20`.

## 1. Prerequisites

- **The image ships no usable login.** Every account is locked, root included, and the sshd
  drop-in `00-arlowe-key-only.conf` sets `PasswordAuthentication no`. SSH accepts keys only.
  Never try `ssh` with a password; it is refused by design.
- **Dev access** is two pieces, both staged before first boot (section 4):
  `/boot/firmware/userconf.txt` (`<user>:<crypt hash>`) creates the account and sets the
  console and `sudo` password; a public key in the slot-A rootfs at
  `/etc/skel/.ssh/authorized_keys` is copied into the new home and is the only way in over SSH.
- `ssh.service` is enabled in the image (`ENABLE_SSH=1`), so no FAT `ssh` file is needed. It is
  harmless if present.
- Bench kit: the unit with the Whisplay attached, an ethernet cable to the dev LAN for the SSH
  session, an iPhone and an Android phone, and a 2.4 GHz home network the unit can join.
- A reset or pairing on the unit only needs `systemctl start`; nothing here enables units.

## 2. Build (build host)

Mechanics: [phase-6-build-flash-deploy.md](phase-6-build-flash-deploy.md) and
[phase-07.3-pi-archive-pinning.md](phase-07.3-pi-archive-pinning.md) section 2. The traps that
have cost builds before:

- Copy the tree to the build host with `rsync -a --delete --exclude build/`, not `git clone`:
  the build host has no repository credentials. Build from a clean worktree.
- Destroy the pi-gen work dir before every full build (`sudo rm -rf build/pi-gen-work`).
- Watch a running build with `pgrep -f 'build-image[.]sh'`. A bare `build-image.sh` pattern
  matches the polling command itself and reports "running" forever.
- Never pipe a password into `sudo -S` inside a pipeline that ends in `tee`: the password lands
  in the file. Run `sudo -v` first, or wrap the whole job in one `sudo bash -c '...'`.

**Stage the SSH key into the image**, on the build host, before the image leaves it. The Mac
cannot write ext4, so this is the one step that must happen on the image:

```bash
LOOP=$(sudo losetup -Pf --show build/arlowe.img)
sudo mount "${LOOP}p2" /mnt                      # slot A
sudo install -d -m 0700 /mnt/etc/skel/.ssh
sudo install -m 0600 ~/.ssh/<key>.pub /mnt/etc/skel/.ssh/authorized_keys
sudo umount /mnt && sudo losetup -d "$LOOP"
bmaptool create -o build/arlowe.img.bmap build/arlowe.img
```

The rw mount rewrites the ext4 superblock, so the `.bmap` from the build no longer matches and
`bmaptool copy` would abort mid-flash. Regenerating it, as above, is mandatory. Any other
inspection of the image mounts read-only (`mount -o ro`).

### Phase 8 build evidence (08-27a)

Built 2026-09-30 from `c057696` (clean worktree, `sudo rm -rf build/pi-gen-work` first),
`CARD_SIZE_GB=32`, `ARLOWE_INPUTS_ACCEPT=1`. `BUILD-EXIT 0` in about 30 minutes;
`build/arlowe.img` is 34359738368 bytes. Log: `build/logs/phase-08-build.log` on the build host.
The key has not been staged yet; that step and the flash belong to 08-27b.

Gates: `Debian resolution pinned: 29 snapshot list files, 0 off-pin`; `Pi archive resolution
pinned: 1 flat-repo list files, 0 off-pin`; `91 manifest packages installed at the pinned
version, 666 installed packages attributed, 0 unattributed`; kernel `6.12.96`; unit substrate,
persistent-journal, sanitize, identity-store and default-login (slot A and slot B) gates passed.

Inputs diff before the re-record: the four new Phase 8 packages and the commit time, nothing else.

```
+pkg python3-argon2             21.1.0-2          arm64
+pkg python3-png                0.20220715.0-1    all
+pkg python3-qrcode             7.4.2-2           all
+pkg python3-typing-extensions  4.4.0-1           all
 source_date_epoch 1790470120 -> 1790737975      (worktree_clean stays true)
```

Rootfs, inspected with a read-only loop device and `mount -o ro` (the `.bmap` sha256 was the
same before and after):

- Slot A `multi-user.target.wants`: `arlowe-pair`, `arlowe-radio-init`,
  `arlowe-factory-reset-resume`, `arlowe-identity-init` and the six runtime units, each resolving
  to a unit file in `/etc/systemd/system`.
- `arlowe-pair-commit.service` and `arlowe-factory-reset@.service` present, 0 target links.
- Present: `51-arlowe-networkmanager.rules`, `arlowe-captive.conf`, `arlowe-wifi-regdom.conf`,
  `arlowe-setup-ap.nft`, `runtime/pair/__main__.py`, `runtime/cli/{pair-commit,factory-reset,radio-init}`.
- `dpkg`: `python3-qrcode`, `python3-argon2`, `python3-png`, `python3-typing-extensions` all
  `install ok installed`.
- `/etc/arlowe/config.yml` absent (factory state).
- `/etc/arlowe` against the image's own `arlowe` GID (992, read from each slot's `etc/group`):

```
slot A (p2): 770 0 992
slot B (p3): 770 0 992
```

Slot B carries none of the repo's units by design: `recovery-stub.sh` removed all 12 from the
clone and enables only `arlowe-recovery.service`. Only slot A needs the unit checks.

## 3. Local broker (dev machine)

Full setup: [scripts/pki/README.md](../../scripts/pki/README.md), section "Local broker for
pairing tests" (lands with the claim-code broker). In outline, with a gitignored working dir:

```bash
python3 -m venv .venv-broker && .venv-broker/bin/pip install -r scripts/pki/requirements.txt
B=build/broker; STORE=$B/claims.json
.venv-broker/bin/python scripts/pki/claim_codes.py --store "$STORE" mint --note "code A"
.venv-broker/bin/python scripts/pki/claim_codes.py --store "$STORE" mint --note "code B"
.venv-broker/bin/python scripts/pki/stub_iot.py tls --san 192.0.2.10 --out "$B/tls"
ARLOWE_BROKER_CLAIM_CODES="$STORE" .venv-broker/bin/python scripts/pki/broker.py \
  --stub-iot --stub-ca-dir "$B/stub-ca" --host 0.0.0.0 --port 8443 \
  --certfile "$B/tls/broker-cert.pem" --keyfile "$B/tls/broker-key.pem"
```

- `mint` prints each code once. Write codes A and B on the box cards; record only the hash
  prefix from `claim_codes.py --store "$STORE" list` in any evidence.
- `--san` must be the address the unit dials. Pin the dev machine's LAN address for the session.
- **The stub keeps certificate state in memory.** Restarting the broker forgets every
  certificate it issued, so a later revoke of one of them fails and lands in the orphan ledger.
  Restart it only where this runbook says to (SC3's issuance failure, before SC2), and not
  between a pairing and the reset that is expected to revoke `ok`.

## 4. Flash and stage the FAT partition (dev machine)

Flash through the Mac's built-in SD slot. **Never use the USB SD reader**: it lands bulk writes
64 KiB low and bmaptool still reports success.

```bash
diskutil list                                        # find the card: /dev/diskN
scripts/flash-sd.sh build/arlowe.img /dev/diskN      # confirms, writes, reads the card back
```

Accept the card only if the script ends with `Flashed and verified` after its
`[flash-verify] ... blocks ... read back` line. A read-back mismatch means do not boot it.

With the card still in the slot, mount the FAT partition (typed EFI, so it does not
auto-mount) and stage the files:

```bash
mkdir -p /tmp/arlowe-boot && sudo diskutil mount -mountPoint /tmp/arlowe-boot /dev/diskNs1
printf '%s:%s\n' <user> "$(openssl passwd -6)" | sudo tee /tmp/arlowe-boot/userconf.txt >/dev/null
python3 -c 'import json,sys; print(json.dumps({"url": sys.argv[1], "ca_bundle_pem": open(sys.argv[2]).read()}))' \
  https://192.0.2.10:8443 build/broker/tls/ca.pem > /tmp/arlowe-broker.json
sudo cp /tmp/arlowe-broker.json /tmp/arlowe-boot/arlowe-broker.json
diskutil eject /dev/diskN
```

`arlowe-broker.json` is `{"url": "https://...", "ca_bundle_pem": "<PEM>"}`. On the unit it is
`/boot/firmware/arlowe-broker.json`, read by `arlowe_broker.resolve_broker` for both pairing
and reset's revoke. The URL is the broker's base; the device appends `/v1/certificates` and
`/v1/certificates/revoke`. A non-https URL is rejected. Leave the file in place until every
reset in section 7 is done: a unit paired against the self-signed broker cannot verify it
without this CA, so a reset would record an orphan instead of revoking.

## 5. SC1: factory boot to the waiting screen

Boot the unit with ethernet attached. Over SSH (`ssh <user>@arlowe.local`, or the DHCP address):

```bash
test -e /etc/arlowe/config.yml && echo "NOT FACTORY STATE" || echo "factory state confirmed"
systemctl is-active arlowe-radio-init arlowe-pair                  # active active
systemctl show -p ConditionResult arlowe-face arlowe-dashboard     # ConditionResult=no, twice
sudo arlowe-boot-check --first-boot                                # ends: READY TO PAIR
stat -c '%a %U:%G' /etc/arlowe                                     # 770 root:arlowe
sudo ss -ltnp 'sport = :80'                                        # 10.42.0.1:80, never 0.0.0.0:80
```

Whisplay: the waiting screen with the SSID `Arlowe-Setup-<4 hex>`, the 12-character session
password as text, and a QR (`WIFI:T:WPA;S:<ssid>;P:<psk>;;`). Scan the QR with the iPhone camera:
it joins, and the captive sheet opens the setup page. Repeat on the Android phone.

**Forward drop.** With ethernet attached, `ip route show default` shows a route via `eth0`. On
a phone joined to the setup network, open `http://1.1.1.1` (an IP literal, because captive DNS
answers every name with `10.42.0.1`): it must not load. `sudo nft list table inet arlowe_setup`
shows the two `wlan0` drops.

## 6. SC3 then SC2: failures first, then a successful pairing

Run SC3 from the waiting screen, before SC2, so the successful pairing also proves recovery
from an error without a power cycle.

**No saved Wi-Fi profile** means, everywhere below, both of:

```bash
sudo grep -l '^type=wifi' /etc/NetworkManager/system-connections/* 2>/dev/null | wc -l   # 0
nmcli -t -f NAME,TYPE connection show | grep 802-11-wireless    # only arlowe-setup, or nothing
```

The in-memory AP profile `arlowe-setup` is present whenever the waiting screen is up, so a bare
count of `802-11-wireless` rows is 1 on a correct unit and cannot be the check.

### SC3: the four failure modes

Submit the form with the correct values except the one the row changes. After each: the
Whisplay shows the string, the setup network returns with **the same password**, the phone
rejoins and the page shows the same string, and there is no saved Wi-Fi profile.

| Failure | How to provoke | Kind | Whisplay and page string |
|---|---|---|---|
| Bad Wi-Fi credentials | Type a wrong home Wi-Fi password | `wifi_rejected` | "Wi-Fi password not accepted" |
| Server unreachable | Stop the broker (Ctrl-C) before submitting | `server_unreachable` | "Can't reach Arlowe servers" |
| Account auth fail | A well-formed code the broker never minted: `claim_codes.py --store build/broker/unminted.json mint` | `claim_rejected` | "Setup code not accepted" |
| Cert issuance fail | Restart the broker with `--stub-fail issuance` added | `cert_failed` | "Couldn't get device certificate" |

The four strings must differ. Afterwards restart the broker without `--stub-fail` and confirm
`claim_codes.py --store "$STORE" list` still shows code A `unused` (a 502 does not spend it).
Optional: a misspelt SSID gives `wifi_not_found`, "Wi-Fi network not found"; a card without
`arlowe-broker.json` gives `not_configured`, "No setup server configured".

**SIGKILL mid-provisioning** (before the four rows): submit correct values with code A; when the
Whisplay shows provisioning, run `sudo systemctl kill -s KILL arlowe-pair`. Within about 10 s,
`systemctl show -p NRestarts,ActiveState arlowe-pair` shows `NRestarts` of at least 1 and
`active`, the waiting screen has a new password, and there is no saved Wi-Fi profile.

### SC2: pairing

From the last SC3 error, correct the form: home Wi-Fi, name "Kitchen Test", a dashboard
password, code A. The page shows `http://kitchen-test.local:3000` and the IP before submit.
Whisplay: connecting, provisioning, then the paired screen with the URL and IP. **Read the IP
now**: the paired screen holds for 30 s or until a button press, then the face takes over.

```bash
ssh <user>@kitchen-test.local        # or the IP from the paired screen
test -f /etc/arlowe/config.yml && hostnamectl --static                 # kitchen-test
systemctl is-active arlowe-face arlowe-voice arlowe-dashboard qwen-tokenizer qwen-api whisper-stt
systemctl show -p ActiveState,Result arlowe-pair                       # inactive, success
sudo arlowe-identity status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["provisioned"], d["device_id"], d["certificate_id"])'
sudo grep -c '^psk=' /etc/NetworkManager/system-connections/*.nmconnection   # 1 for the home SSID; count only
```

On the phone, open the URL: the login page appears, the pairing password logs in, the dashboard
loads. Change the audio output on the dashboard and save, then confirm the pairing keys survived:

```bash
sudo python3 -c "import yaml;c=yaml.safe_load(open('/etc/arlowe/config.yml'));print(c['device']['hostname'], bool(c['identity']['provisioning_url']), 'owner' in c, 'network' in c)"
```

**Journal secret check.** Type each secret into a variable, never into a file or a command line:

```bash
read -rs PSK; read -rs DASH_PW; read -rs CLAIM; read -rs SETUP_PSK
sudo journalctl -b --no-pager | grep -cF -e "$PSK" -e "$DASH_PW" -e "$CLAIM" -e "$SETUP_PSK"   # 0
unset PSK DASH_PW CLAIM SETUP_PSK
```

**Paired reboot.** `sudo reboot`; afterwards the six are `active`, `systemctl show -p
ConditionResult arlowe-pair` is `no`, and `nmcli -t -f GENERAL.CONNECTION device show wlan0`
names the home SSID (the persisted PSK rejoined).

## 7. SC4: the three reset triggers

Before each reset, record the identity it should replace:

```bash
sudo arlowe-identity status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["device_id"], d["certificate_id"])'
```

After each reset the unit reboots into pairing. Check, over ethernet (the hostname is back to
`arlowe`, so `arlowe.local`):

```bash
test -e /etc/arlowe/config.yml && echo "STILL PAIRED" || echo "unpaired"
sudo cat /var/lib/arlowe/identity/device-id              # differs from the recorded id
sudo ls /var/lib/arlowe/identity/                        # no device.crt
sudo ls -A /var/lib/arlowe/conversations /var/lib/arlowe/dashboard   # empty skeleton
sudo tail -1 /var/lib/arlowe/reset-ledger/resets.log     # {at, trigger, revoke}
sudo journalctl -b -1 -u 'arlowe-factory-reset@*' --no-pager | tail -20
```

plus no saved Wi-Fi profile (section 6) and `systemctl is-active arlowe-pair` = `active`.

**a. Dashboard.** Use the dashboard's factory-reset control and re-enter the password. It starts
`arlowe-factory-reset@dashboard.service`. Expect `trigger: dashboard, revoke: ok`, the broker
log shows the revoke, and `claim_codes.py list` shows code A `unused` again (the revoke
released it).

**b. Button.** Pair again with code A (proves the release). When the paired screen appears,
pull power about 10 s into the 30 s hold and restore it: the six come up `active` and
`arlowe-pair` has `ConditionResult=no`. Then hold the Whisplay button 10 s (countdown from 3 s,
LED red at 10 s), release, and press again within 5 s. It starts
`arlowe-factory-reset@button.service`. Expect `trigger: button, revoke: ok`.

**c. Offline reset.** Pair with code B, stop the broker, reset from the dashboard. Expect
`revoke: failed`, one new line in `/var/lib/arlowe/reset-ledger/orphaned-certs.jsonl`
(`{certificate_id, thing_name, device_id, at, reason}`), and the unit still lands in pairing.
Code B stays bound to the orphaned id until the operator releases it:

```bash
.venv-broker/bin/python scripts/pki/claim_codes.py --store "$STORE" release <code B>
```

Against real AWS IoT, also revoke the orphan: `scripts/pki/revoke.sh <certificate_id>` with the
id from the ledger line. Against the stub there is nothing to revoke once it has restarted.

**d. Recovery SD card.** The third trigger is a reflash, documentation only (ADR-0013). Flash the
current image to the unit's card, or to a spare card, exactly as in section 4, and boot it. The
unit lands in pairing: no `config.yml`, a new `device_id` from fresh entropy, empty owner data,
no saved Wi-Fi profile. A reflash rewrites every partition, the reset ledger included, so it
leaves no record. The operator releases by hand:

1. If the old card still boots, record `sudo arlowe-identity status --json` (device id and
   certificate id) before reflashing. Otherwise take the device id from `claim_codes.py list`.
2. Release the owner's claim code: `claim_codes.py --store "$STORE" release <code>`.
3. Against real AWS IoT, revoke the old certificate with `scripts/pki/revoke.sh
   <certificate_id>` (list it with `aws iot list-thing-principals --thing-name <device_id>`).

Until step 2 runs, the owner's card is refused on the reflashed unit with "Setup code not
accepted", because the code is bound to the old device id.

## 8. Diagnostics

```bash
systemd-run --uid=arlowe --pipe nmcli general permissions   # yes for network-control,
  # settings.modify.system, wifi.share.protected, wifi.scan, enable-disable-wifi
iw reg get                                                  # country US
lsmod | grep cfg80211                                       # loaded (the regdomain conf needs it)
journalctl -b -u arlowe-radio-init -u arlowe-pair --no-pager
sudo nft list table inet arlowe_setup
```

A wrong home PSK is reported by brcmfmac with reason code 7, 8 or 11; record which one.

## 9. Evidence template

Copy per run. Record commands and outputs verbatim; never a secret, only presence or counts.
Anything not observed is written "not observed".

```
Run: <date>  image: <commit>  card: <size>  flash read-back: <line>
Claim codes: A <hash prefix>  B <hash prefix>

SC1  factory state confirmed:                <output>
SC1  arlowe-pair active, face/dashboard ConditionResult=no: <output>
SC1  boot-check READY TO PAIR:               <output>
SC1  /etc/arlowe 770 root:arlowe:            <output>
SC1  portal bound 10.42.0.1:80:              <output>
SC1  Whisplay SSID/password/QR:              <observed>
SC1  iPhone QR join + captive page:          <observed>
SC1  Android QR join + captive page:         <observed>
SC1  forward drop (1.1.1.1 fails, nft table): <observed / output>
SC3  SIGKILL: NRestarts, new password, no profile: <output>
SC3  wifi_rejected    Whisplay | page | no profile: <observed | observed | output>
SC3  server_unreachable Whisplay | page | no profile: <...>
SC3  claim_rejected   Whisplay | page | no profile: <...>
SC3  cert_failed      Whisplay | page | no profile | code A unused: <...>
SC2  paired screen held (seconds):           <observed>
SC2  config.yml, hostname, six active, pair exited success: <output>
SC2  certificate present:                    <output>
SC2  home PSK persisted (count):             <output>
SC2  login page, password accepted, dashboard: <observed>
SC2  audio save keeps hostname/identity/owner/network: <output>
SC2  journal secret grep = 0:                <output>
SC2  paired reboot: six active, pair skipped, rejoined: <output>
SC4a dashboard: unpaired, new id, no cert, empty data, no profile, resets.log, code A unused: <output>
SC4b power pull during hold: six active, pair skipped: <output>
SC4b button: same checks, trigger button:    <output>
SC4c offline: orphan line, revoke failed, pairing, code B released: <output>
SC4d recovery SD: section 7d read and correct: <yes/no>
Diag nmcli permissions / iw reg / cfg80211 / brcmfmac reason: <output>
```
