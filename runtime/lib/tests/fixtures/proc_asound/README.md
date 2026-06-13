# proc_asound fixtures

Captured-shape `/proc/asound` trees used by `test_arlowe_audio.py`. They are
minimal but real-shaped snapshots — no real device serials; `usbid` files are
empty stubs whose presence is the only thing checked.

## Layout

```
usb_plus_wm8960/   card0=wm8960 (cap+play), card1=USB (cap+play), card2=vc4-hdmi (play)
wm8960_only/       card0=wm8960 (cap+play), card1+card2=vc4-hdmi (play only)
no_capture/        card0+card1=vc4-hdmi (play only) — genuine no-mic case
two_usb_capture/   card0=USB-A (cap+play), card1=USB-B (cap+play) — tie-break test
```

Each fixture tree mirrors the structure `enumerate_cards()` reads:

- `cards`          — the `/proc/asound/cards` listing (index, bracketed id, longname)
- `card<N>/id`     — stable card-id token (authoritative; may differ from bracketed name)
- `card<N>/usbid`  — presence indicates a USB audio card (contents irrelevant)
- `card<N>/pcm*c/` — directory presence indicates capture capability
- `card<N>/pcm*p/` — directory presence indicates playback capability
