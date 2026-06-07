# Phase 4 persona slice — SC4 verification procedure

The persona knob is the one CONFIG-06 knob with a live end-to-end consumer in
Phase 4 (the others are defined + validated but consumed in Phases 7–11). This
doc is the manual verification for **SC2** (refuse to start on a bad overlay) and
**SC4** (a knob change restarts the service and takes effect).

The chain: dashboard validates (ajv) + atomically writes `/etc/arlowe/config.yml`
+ restarts `arlowe-face` (plan 04-03) → `arlowe-face` reads
`persona.sentiment_mapping` from the merged+validated overlay via the shared
loader (`runtime/face/sentiment_classifier.py`) → `ExecStartPre` runs
`arlowe_config_validate` and exits 78 on a bad overlay (plan 04-04).

Run on a Pi with Phase 4 provisioned (the runtime services installed under
`/opt/arlowe`, the dashboard reachable on `http://localhost:3000`).

## 1. Baseline — absent overlay (SC3)

```bash
ls /etc/arlowe/config.yml          # expect: No such file (pre-pairing state)
systemctl status arlowe-face       # expect: active (running)
```
Face uses `DEFAULT_MAPPING` (positive → happy). No crash, no error in the journal.

## 2. Persona change → restart → effect (SC4)

Through the dashboard Settings, or directly:

```bash
curl -sS -X POST http://localhost:3000/api/config \
  -H 'Content-Type: application/json' \
  -d '{"persona":{"sentiment_mapping":{"positive":["excited"]}}}'
# expect: HTTP 200
cat /etc/arlowe/config.yml          # now exists, valid YAML, positive: [excited]
journalctl -u arlowe-face -n 20     # shows the unit restarted
```

Then trigger a positive-sentiment interaction and confirm the face shows the
**excited** expression rather than the default **happy**. (Deep-merge preserved
the untouched `negative`/`neutral` siblings — verify they still behave.)

## 3. Fail-fast on an invalid overlay (SC2)

Reject at the write boundary:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/api/config \
  -H 'Content-Type: application/json' -d '{"ota":{"channel":"purple"}}'
# expect: 422, and /etc/arlowe/config.yml UNCHANGED
```

Then prove the service-level fail-fast (write a bad overlay directly and restart):
```bash
sudo tee /etc/arlowe/config.yml >/dev/null <<'EOF'
ota:
  channel: purple
EOF
sudo systemctl restart arlowe-face
systemctl status arlowe-face        # expect: failed
journalctl -u arlowe-face -n 20     # expect: [arlowe-config] schema violation ... ; status=78

# qwen chain: tokenizer fails, and qwen-api (Requires=qwen-tokenizer) is blocked
sudo systemctl restart qwen-tokenizer   # expect: failed (exit 78)
sudo systemctl start qwen-api            # expect: blocked / dependency failed
```

Restore: remove the bad overlay (or write a valid one) and restart the services.

## Notes

- `ExecStartPre` execution is where the python loader actually runs against the
  installed `jsonschema`/`PyYAML` — the Phase-4 Docker testbed is stat-only, so
  this on-device run is the real validator-execution check.
- `qwen-api.service` has no python venv (native `run_api.sh`); the validator
  lives on `qwen-tokenizer.service`, which `qwen-api` `Requires=`, so a bad
  overlay fail-fasts the whole qwen chain without touching qwen-api.
- Record pass/fail per step in `04-04-SUMMARY.md`.
