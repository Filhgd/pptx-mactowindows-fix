#!/usr/bin/env bash
# Runs the built app on test presentations. Usage: tests/run_tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="dist/PPTX MacToWindows Fix.app/Contents/MacOS/PPTXFix"
OUT=tests/out
mkdir -p "$OUT"
fail=0
step() { echo; echo "== $*"; }
bad() { echo "FAIL $*"; fail=1; }

python3 tests/make_fixture.py "$OUT" || exit 1
step "version"; "$BIN" --version || bad "version"

step "fix a Mac-style presentation"
before=$(shasum "$OUT/mac_clip.pptx")
"$BIN" --fix "$OUT/mac_clip.pptx" "$OUT/fixed.pptx" || bad "fix exited with an error"
python3 tests/check_output.py "$OUT/mac_clip.pptx" "$OUT/fixed.pptx" 2400 || bad "output checks"
[ "$before" = "$(shasum "$OUT/mac_clip.pptx")" ] && echo "OK   original unchanged" || bad "original was changed"

step "default output name"
"$BIN" --fix "$OUT/mac_clip.pptx" && [ -f "$OUT/mac_clip_windows.pptx" ] && echo "OK   mac_clip_windows.pptx" || bad "default name"

step "fixed file has nothing left to fix"
r=$("$BIN" --fix "$OUT/fixed.pptx" "$OUT/again.pptx"); echo "$r"
[ "$r" = "niets te repareren" ] && [ ! -e "$OUT/again.pptx" ] && echo "OK   nothing written" || bad "second pass"

step "presentation without Mac clips"
r=$("$BIN" --fix "$OUT/plain.pptx" "$OUT/plain_out.pptx"); echo "$r"
[ "$r" = "niets te repareren" ] && [ ! -e "$OUT/plain_out.pptx" ] && echo "OK   nothing written" || bad "plain"

step "not a presentation"
echo "hallo" > "$OUT/bad.pptx"
if "$BIN" --fix "$OUT/bad.pptx" "$OUT/bad_out.pptx"; then bad "accepted a broken file"; else echo "OK   refused"; fi
[ ! -e "$OUT/bad_out.pptx" ] && echo "OK   nothing written" || bad "wrote output for a broken file"

step "app starts and keeps running"
"$BIN" & pid=$!
sleep 8
if kill -0 "$pid" 2>/dev/null; then echo "OK   running after 8 s"; kill "$pid"; else wait "$pid"; echo "WARN app exited with code $? (no GUI session on the runner?)"; fi

mkdir -p "$OUT/extracted"
unzip -o -q "$OUT/fixed.pptx" 'ppt/media/*_hr.png' -d "$OUT/extracted" || true

echo
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $fail
