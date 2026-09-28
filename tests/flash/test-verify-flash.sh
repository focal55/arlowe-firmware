#!/usr/bin/env bash
# Self-test for scripts/lib/verify-flash.py, the read-back check flash-sd.sh runs
# after writing a card. Regular files stand in for the image and the card.
# The [shifted-64k] case reproduces the reader defect that shipped a corrupt
# card while bmaptool reported success (07.3-08, boot test).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="${REPO_ROOT}/scripts/lib/verify-flash.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0; FAILED=0
# ok STATUS NAME: STATUS is the exit status of the assertion just evaluated.
ok() { if [[ $1 -eq 0 ]]; then echo "[OK]   $2"; PASSED=$((PASSED+1)); else echo "[FAIL] $2"; echo "  ${OUT//$'\n'/$'\n'  }"; FAILED=$((FAILED+1)); fi; }
run() { OUT="$(python3 "${VERIFY}" "$@" 2>&1)"; RC=$?; }

BS=4096
IMG="${WORK}/img"; head -c $((64 * BS)) /dev/urandom > "${IMG}"
# Blocks 0-15 and 32-47 mapped; 16-31 and 48-63 are holes bmaptool never writes.
cat > "${WORK}/img.bmap" <<EOF
<?xml version="1.0" ?>
<bmap version="2.0">
    <ImageSize> $((64 * BS)) </ImageSize>
    <BlockSize> ${BS} </BlockSize>
    <BlocksCount> 64 </BlocksCount>
    <MappedBlocksCount> 32 </MappedBlocksCount>
    <BlockMap>
        <Range chksum="x"> 0-15 </Range>
        <Range chksum="x"> 32-47 </Range>
    </BlockMap>
</bmap>
EOF
card() { cp "${IMG}" "$1"; head -c $((16 * BS)) /dev/urandom >> "$1"; }  # a card is larger than the image
corrupt() { printf 'X' | dd of="$1" bs=1 seek="$2" conv=notrunc status=none; }

card "${WORK}/c1"; run "${IMG}" "${WORK}/c1"
[[ ${RC} -eq 0 && "${OUT}" == *"0 differ"* ]]; ok $? "[identical] a faithful copy passes"

card "${WORK}/c2"; corrupt "${WORK}/c2" $((40 * BS + 7)); run "${IMG}" "${WORK}/c2"
[[ ${RC} -eq 1 && "${OUT}" == *"$((40 * BS))"* ]]; ok $? "[one-byte] a single changed byte fails and names its block offset"

card "${WORK}/c3"; corrupt "${WORK}/c3" $((20 * BS)); run "${IMG}" "${WORK}/c3" --bmap "${WORK}/img.bmap"
[[ ${RC} -eq 0 ]]; ok $? "[unmapped] with --bmap, a difference in a hole bmaptool skips is ignored"

run "${IMG}" "${WORK}/c3"
[[ ${RC} -eq 1 ]]; ok $? "[whole-image] without --bmap, the same difference fails"

# Blocks 32-47 written 64 KiB (16 blocks) low, as the reader did: card block X holds image block X+16.
card "${WORK}/c4"
dd if="${IMG}" of="${WORK}/c4" bs=${BS} skip=32 seek=16 count=16 conv=notrunc status=none
dd if=/dev/urandom of="${WORK}/c4" bs=${BS} seek=32 count=16 conv=notrunc status=none
run "${IMG}" "${WORK}/c4" --bmap "${WORK}/img.bmap"
[[ ${RC} -eq 1 && "${OUT}" == *"16 differ"* ]]; ok $? "[shifted-64k] writes landing 64 KiB low fail even though every byte was written somewhere"

head -c $((10 * BS)) "${IMG}" > "${WORK}/short"; run "${IMG}" "${WORK}/short"
[[ ${RC} -eq 1 && "${OUT}" == *"shorter"* ]]; ok $? "[short-target] a target smaller than the image fails"

run "${IMG}"
[[ ${RC} -eq 2 && "${OUT}" == *usage* ]]; ok $? "[usage] a missing argument exits 2"

echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
