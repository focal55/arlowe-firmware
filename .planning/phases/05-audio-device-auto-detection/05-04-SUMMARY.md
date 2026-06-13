---
phase: 05-audio-device-auto-detection
plan: 04
type: summary
wave: 2
package: security
status: complete
---

# 05-04 SUMMARY — Dashboard audio device picker + /api/audio/devices endpoint

## Endpoint contract

`GET /api/audio/devices` returns:

```json
{
  "capture": [{ "id": "<card-id-token>", "name": "<friendly name>", "index": 0 }],
  "playback": [{ "id": "<card-id-token>", "name": "<friendly name>", "index": 0 }]
}
```

- Always returns HTTP 200. On missing `/proc/asound` (dev container, non-Pi), returns `{ capture: [], playback: [] }` and logs the error.
- `id` is the stable card-id token read from `/proc/asound/card{N}/id`. Used as the stored value in `/etc/arlowe/config.yml`.
- Classification uses `/proc/asound/card{N}/` directory entries: `pcm*c` = capture capable, `pcm*p` = playback capable.
- Env var `ARLOWE_PROC_ROOT` (default `/proc`) overrides the procfs root for testing.

## Friendly-name mapping rules (in priority order)

| Match on longname | Friendly label |
|---|---|
| contains `wm8960` | `Whisplay Speaker/Mic (WM8960)` |
| contains `usb` | `USB Audio Device (<longname>)` |
| contains `hdmi` | `HDMI <n>` (n from longname or card index) |
| fallback | raw longname |

## Config preselection

`GET /api/config` exists (added in Phase 4, `app/api/config/route.ts`). The `/audio` page calls it on mount and reads `config.audio.capture_device` / `config.audio.playback_device` to preselect the current override. If the device is unpaired or the GET fails, both dropdowns default to "Auto".

## Phase 4 write path — reused unmodified

`POST /api/config` is called unchanged with body:

```json
{ "audio": { "capture_device": "<id-or-auto>", "playback_device": "<id-or-auto>" } }
```

This triggers the existing Phase 4 flow: AJV validation, atomic write to `/etc/arlowe/config.yml`, then `arlowe-voice.service` restart via `restart-map.ts` (`audio → arlowe-voice.service`). No edits to `config/route.ts` or `restart-map.ts`.

## Security notes (package:security)

- Endpoint reads procfs exclusively via `fs.readFile` / `fs.readdir` — no shell, no `child_process`, no `/dev/snd`.
- Path interpolation is constrained to integer card indices parsed from `/proc/asound/cards` — no user-supplied input reaches any file path.
- `grep -n "child_process\|exec(" runtime/dashboard/app/api/audio/devices/route.ts` returns nothing.

## Files modified

- `runtime/dashboard/app/api/audio/devices/route.ts` — new, enumeration endpoint
- `runtime/dashboard/app/audio/page.tsx` — new, picker page
- `runtime/dashboard/app/audio/components/AudioDevicePicker.tsx` — new, two-dropdown component
- `runtime/dashboard/app/components/Navigation.tsx` — nav link added

## Verification

- `tsc --noEmit`: pass
- `pnpm test:unit`: 9/9 pass (existing tests unaffected)
- `pnpm lint` (new files only): clean; pre-existing `react-hooks/set-state-in-effect` errors in unrelated files remain unchanged
