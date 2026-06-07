---
phase: 04-config-overlay
plan: 04
status: complete
closure: passed-with-notes
provides:
  - arlowe-face consumes persona.sentiment_mapping from the merged+validated YAML overlay via the shared arlowe_config loader (deep-merge over defaults); absent overlay returns defaults without raising (SC3 preserved). Reconciles the prior JSON/top-level-sentiment_mapping path.
  - SC2 fail-fast — ExecStartPre arlowe_config_validate on the three python-bearing units (arlowe-face + arlowe-voice via /opt/arlowe/venvs/voice; qwen-tokenizer via /opt/arlowe/venvs/llm). A schema-violating overlay exits 78 and the unit refuses to start. qwen-tokenizer gates the qwen chain (qwen-api Requires=qwen-tokenizer and has no venv of its own); qwen-api.service untouched.
  - CONFIG-06 persona knob has a live consumer; the other knobs (hostname, support_mode, ota, logs) are defined+validated in 04-01 but consumed in Phases 7-11 by design.
affects:
  - Phase 6 (image build) — runs the on-device SC4 end-to-end (dashboard persona change → arlowe-face restart → visible expression change) and the real validator-execution check. Procedure ready in docs/operations/phase-4-persona-slice.md.
  - Phase 10 — re-harden ota.channel_url + support_mode.* writes behind support-mode re-auth (per ADR-0003).
  - Phase 11 — persona is the proven dashboard-knob pattern for the settings view.
files_written:
  - runtime/face/sentiment_classifier.py
  - runtime/face/tests/test_persona_overlay.py
  - units/arlowe-face.service
  - units/arlowe-voice.service
  - units/qwen-tokenizer.service
  - docs/operations/phase-4-persona-slice.md
---

## What landed

The persona config knob, end-to-end on the consumer + fail-fast side:

- **`runtime/face/sentiment_classifier.py`** — `load_config()` now reads
  `persona.sentiment_mapping` from the shared loader (`from arlowe_config import
  load`), which deep-merges the optional `/etc/arlowe/config.yml` overlay over
  `defaults.yml` and validates. Resilient fallbacks (direct YAML read → legacy JSON
  state → `DEFAULT_MAPPING`); absent overlay is the normal pre-pairing state and
  never raises (SC3). Public signatures unchanged, so `face_service.py` is unaffected.
- **`units/{arlowe-face,arlowe-voice,qwen-tokenizer}.service`** — added a
  non-`-`-prefixed `ExecStartPre=… -m arlowe_config_validate` with the correct venv
  interpreter, and `PYTHONPATH += /opt/arlowe/runtime/lib`. A bad overlay fail-fasts
  start (SC2). The validator lives on qwen-tokenizer (not the venv-less qwen-api),
  gating the qwen chain via `Requires=`.
- **`runtime/face/tests/test_persona_overlay.py`** — 2 pytest cases: a partial
  persona overlay overrides one sentiment and deep-merge preserves the siblings; an
  absent overlay returns defaults without raising.
- **`docs/operations/phase-4-persona-slice.md`** — the SC4 verification procedure.

## Verification

- `pytest runtime/face/tests/test_persona_overlay.py` — 2/2 green (against real
  `jsonschema` 4.23.0 + `PyYAML` 6.0.3).
- Sanitize gate green; `git diff --quiet units/qwen-api.service` (untouched).
- Units edited per plan; `systemd-analyze verify` deferred to the Pi/image (not on macOS).

## Note (why passed-with-notes): SC4 deferred to Phase 6

The on-device SC4 end-to-end — dashboard persona change → `arlowe-face` restart →
**visible** expression change — could not be run on `arlowe-1`. Confirmed via ssh:
the dev Pi has **no `arlowe` user, no `/opt/arlowe`, no `/etc/arlowe`, no system
`arlowe-face.service`, and no venv with `jsonschema`/`PyYAML`**. Its daily-driver
runs as `focal55` under `--user` units with the pre-firmware code. Phase 4's runtime
only exists in the arlowe layout, which is built by the **Phase 6 image** — so the
running-services SC4 check belongs there (same deferral shape as Phase 1 SC4 → Phase
12 and Phase 3 SC4 → staging/image). The procedure is written and ready to run when
the image exists.

This closes Phase 4 **passed-with-notes**: CONFIG-01..06 are implemented and
unit/sanitize-verified; the one hardware-bound demonstration (SC4 persona on a
running face) is deferred to Phase 6/12.
</content>
