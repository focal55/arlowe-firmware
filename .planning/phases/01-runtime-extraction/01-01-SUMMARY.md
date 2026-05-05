---
plan: 01-01
phase: 01-runtime-extraction
status: complete
---

# Plan 01 Summary: Scaffold runtime/ and third_party/

## Directory tree created

```
runtime/
  voice/        (Stream A landing zone)
  face/         (Stream A landing zone)
  stt/          (Stream A landing zone)
  tts/          (Stream A landing zone)
  llm/          (Stream A landing zone)
  dashboard/    (Stream B landing zone)
  wake-word/    (Stream D landing zone)
  cli/          (Stream D landing zone)

third_party/
  ax-llm/       (Stream C submodule mount point — placeholder; plan 09 replaces with git submodule)
  axcl/         (Stream C deb vendoring mount point)
```

All directories carry `.gitkeep` files so they commit to git when empty.

## scripts/dev-pull-from-pi.sh interface

```
Usage: dev-pull-from-pi.sh [--apply] [-h|--help]

  --apply    Actually copy files (default is dry-run)
  -h, --help Show usage and exit
```

Targets rsynced from `arlowe-1`:

| Remote path | Local stash |
|---|---|
| `~/iol-monorepo/packages/whisplay/` | `.dev-stash/arlowe-1/whisplay/` |
| `~/iol-monorepo/packages/arlowe-dashboard/` | `.dev-stash/arlowe-1/arlowe-dashboard/` |
| `~/bin/` | `.dev-stash/arlowe-1/bin/` |
| `~/wake_word/` | `.dev-stash/arlowe-1/wake_word/` (*.pkl, positive/, negative/ excluded) |
| `~/.config/systemd/user/` | `.dev-stash/arlowe-1/systemd-user/` |
| `~/iol-monorepo/packages/whisplay/systemd/` | `.dev-stash/arlowe-1/systemd-whisplay/` |
| `~/models/Qwen2.5-7B-Instruct/run_api.sh` | `.dev-stash/arlowe-1/llm/run_api.sh` |
| `~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py` | `.dev-stash/arlowe-1/llm/qwen2.5_tokenizer_uid.py` |

Default mode is dry-run (`rsync --dry-run`). Runs `--apply` to copy. Founder biometric data (`*.pkl`, `positive/`, `negative/`) is always excluded.

## Prerequisite status

This plan is the prerequisite for every other Phase 1 plan (EXTRACT-01 through EXTRACT-12). All plans that land files into `runtime/` or `third_party/` depend on this scaffold existing first. Wave 1 of 6 — must close before any other Phase 1 issue starts.
