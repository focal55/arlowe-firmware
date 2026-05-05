#!/usr/bin/env bash
# Pull source files from arlowe-1.local into .dev-stash/arlowe-1/
#
# By default this performs a dry-run. Pass --apply to actually copy files.
# Biometric data (*.pkl, positive/, negative/) is always excluded.
#
# Usage:
#   scripts/dev-pull-from-pi.sh [--apply] [-h|--help]

set -euo pipefail

REMOTE="arlowe-1"
STASH_ROOT=".dev-stash/arlowe-1"
DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [-h|--help]

Pull source files from ${REMOTE}.local into ${STASH_ROOT}/.

Options:
  --apply    Actually copy files (default is dry-run; prints what would change)
  -h, --help Show this message and exit

Targets mirrored:
  ~/iol-monorepo/packages/whisplay/   -> ${STASH_ROOT}/whisplay/
  ~/iol-monorepo/packages/arlowe-dashboard/ -> ${STASH_ROOT}/arlowe-dashboard/
  ~/bin/                              -> ${STASH_ROOT}/bin/
  ~/wake_word/                        -> ${STASH_ROOT}/wake_word/  (*.pkl, positive/, negative/ excluded)
  ~/.config/systemd/user/             -> ${STASH_ROOT}/systemd-user/
  ~/iol-monorepo/packages/whisplay/systemd/ -> ${STASH_ROOT}/systemd-whisplay/
  ~/models/Qwen2.5-7B-Instruct/run_api.sh           -> ${STASH_ROOT}/llm/run_api.sh
  ~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py -> ${STASH_ROOT}/llm/qwen2.5_tokenizer_uid.py
EOF
}

for arg in "$@"; do
  case "$arg" in
    --apply) DRY_RUN=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

RSYNC_FLAGS="-avz --delete-excluded"
if $DRY_RUN; then
  RSYNC_FLAGS="${RSYNC_FLAGS} --dry-run"
  echo "[dry-run] Pass --apply to copy files."
fi

mkdir -p "${STASH_ROOT}/llm"

run_rsync() {
  local src="$1"
  local dst="$2"
  shift 2
  echo ""
  echo "--- ${src} -> ${dst}"
  rsync ${RSYNC_FLAGS} "$@" "${REMOTE}:${src}" "${dst}"
}

# shellcheck disable=SC2086
run_rsync "~/iol-monorepo/packages/whisplay/"     "${STASH_ROOT}/whisplay/"
run_rsync "~/iol-monorepo/packages/arlowe-dashboard/" "${STASH_ROOT}/arlowe-dashboard/"
run_rsync "~/bin/"                                "${STASH_ROOT}/bin/"
run_rsync "~/wake_word/"                          "${STASH_ROOT}/wake_word/" \
  --exclude='*.pkl' --exclude='positive/' --exclude='negative/'
run_rsync "~/.config/systemd/user/"              "${STASH_ROOT}/systemd-user/"
run_rsync "~/iol-monorepo/packages/whisplay/systemd/" "${STASH_ROOT}/systemd-whisplay/"

# Single-file targets — rsync to a directory with trailing slash requires the parent to exist.
echo ""
echo "--- ~/models/Qwen2.5-7B-Instruct/run_api.sh -> ${STASH_ROOT}/llm/"
rsync ${RSYNC_FLAGS} \
  "${REMOTE}:~/models/Qwen2.5-7B-Instruct/run_api.sh" \
  "${STASH_ROOT}/llm/"

echo ""
echo "--- ~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py -> ${STASH_ROOT}/llm/"
rsync ${RSYNC_FLAGS} \
  "${REMOTE}:~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py" \
  "${STASH_ROOT}/llm/"

echo ""
echo "All targets synced from ${REMOTE}."
if $DRY_RUN; then
  echo "[dry-run] No files were written. Re-run with --apply to copy."
fi
