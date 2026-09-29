---
phase: 08-first-boot-pairing-and-wake-word
plan: 12
subsystem: pairing
tags: [captive-portal, http.server, form-validation, stdlib]
requires: ["08-03 arlowe_hostname", "08-07 pair.errors"]
provides:
  - "pair.portal.make_server(state, on_submit, host, port, portal_host='10.42.0.1')"
  - "pair.portal.validate_form(fields, previous) -> dict, raises FormError(field, message)"
affects: [08-13 pairing flow, 08-27b hardware checkpoint]
tech-stack:
  added: []
  patterns: ["Answer and flush, then hand off on a new thread", "Log method + query-less path + status only"]
key-files:
  created: [runtime/pair/portal.py, runtime/pair/tests/test_portal.py]
  modified: []
key-decisions:
  - "A blank secret returns None (reuse the held value) only when state.has_previous flags it; a blank PSK with none held is an open network ('')"
  - "Claim code normalized like scripts/pki/claim_codes.normalize (I/L->1, O->0, drop '-' and spaces) and passed on as the 20-char canonical form"
  - "SSID from the typed field wins over the scan pick; control characters refused"
duration: 25min
completed: 2026-09-29
---

# Phase 8 Plan 12: Captive Setup Portal Summary

**Stdlib ThreadingHTTPServer that redirects every foreign Host to http://10.42.0.1/, validates the setup form purely, answers before handing off, and never logs a body or query string.**

## Accomplishments
- Probes for iOS, Android, Windows and Firefox get `302 Location: http://10.42.0.1/`; every response carries `Cache-Control: no-store` and `Connection: close`.
- `GET /` renders the cached scan (escaped), a typed-SSID field, all secret fields empty, the `.local:3000` sentence (real slug once a name is known, IP when `ip_hint` is set), and "If anything goes wrong, reconnect to <ap_ssid> and reload this page". No JavaScript.
- `POST /pair`: 8 KB cap (413), 400 with the form re-rendered and `data-error="<field>"` on failure, 200 "Switching networks..." then `on_submit(form)` on thread `pair-submit`.
- `GET /status` -> `{status, error_kind, message}`, message from `pair.errors.MESSAGES`.

## Task Commits
1. Task 1 (RED): `4b51bfd` test(08-12): add failing cases for the captive setup portal
2. Task 2 (GREEN): `0b80d69` feat(08-12): captive setup portal with pure form validation

## Verification
- `PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_portal.py -q --import-mode=importlib`: 21 passed (RED: ImportError on collection).
- `runtime/pair/tests` + `tests/phase-8`: 66 passed.
- Mutation check: logging `self.requestline` makes `test_no_secret_is_logged` fail.
- `scripts/sanitize/check.sh --grep-only`: clean.
- Real iOS/Android captive-sheet behaviour is not verified here; it needs hardware (08-27b).

## Deviations from Plan
1. **State key `ap_ssid` added** (not in the plan's list) for the reconnect sentence; falls back to "the Arlowe-Setup network".
2. **Form result shape**: `{ssid, psk, display_name, slug, password, claim_code}`; secrets may be `None` meaning "reuse".
3. **Size**: 266 + 234 = 500 code lines vs the plan's 360 (tests carry a real-server fixture and 21 parametrized cases). Under the 600 cap.
4. The test fixture runs `serve_forever(0.05)` so teardown does not wait the default 0.5 s poll.

## Next Phase Readiness
08-13 (flow) must: keep `state` current (`status`, `error_kind` as an ErrorKind value, `networks` from `NetMan.scan()`, `last_form` with only ssid/name, `has_previous`, `ap_ssid`, `ip_hint`); substitute held secrets for `None`; bind `10.42.0.1:80`; refuse a second submission while one is in flight (the portal calls `on_submit` for every valid POST).
