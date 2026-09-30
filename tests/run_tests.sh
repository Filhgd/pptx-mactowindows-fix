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
[ "$r" = "nothing to fix" ] && [ ! -e "$OUT/again.pptx" ] && echo "OK   nothing written" || bad "second pass"

step "presentation without Mac clips"
r=$("$BIN" --fix "$OUT/plain.pptx" "$OUT/plain_out.pptx"); echo "$r"
[ "$r" = "nothing to fix" ] && [ ! -e "$OUT/plain_out.pptx" ] && echo "OK   nothing written" || bad "plain"

step "not a presentation"
echo "hello" > "$OUT/bad.pptx"
if "$BIN" --fix "$OUT/bad.pptx" "$OUT/bad_out.pptx"; then bad "accepted a broken file"; else echo "OK   refused"; fi
[ ! -e "$OUT/bad_out.pptx" ] && echo "OK   nothing written" || bad "wrote output for a broken file"

step "batch: several files at once"
mkdir -p "$OUT/batch"
cp "$OUT/mac_clip.pptx" "$OUT/batch/one.pptx"
cp "$OUT/mac_clip.pptx" "$OUT/batch/two.pptx"
cp "$OUT/plain.pptx" "$OUT/batch/three.pptx"
cp "$OUT/bad.pptx" "$OUT/batch/four.pptx"
"$BIN" --fix-all "$OUT"/batch/*.pptx; code=$?
[ $code -eq 1 ] && echo "OK   exit code 1 because one file is broken" || bad "batch exit code $code"
[ -f "$OUT/batch/one_windows.pptx" ] && [ -f "$OUT/batch/two_windows.pptx" ] && echo "OK   two Windows versions" || bad "batch outputs"
[ ! -e "$OUT/batch/three_windows.pptx" ] && [ ! -e "$OUT/batch/four_windows.pptx" ] && echo "OK   no output for the other two" || bad "batch extra outputs"
python3 tests/check_output.py "$OUT/batch/two.pptx" "$OUT/batch/two_windows.pptx" 2400 > /dev/null && echo "OK   batch output passes all checks" || bad "batch output checks"

step "watched folder, end to end (real app, real file events)"
DOMAIN=be.haegdorens.pptxmactowindowsfix
W="$PWD/$OUT/watched"
mkdir -p "$W/sub"
defaults write $DOMAIN watchFolder "$W"
defaults write $DOMAIN welcomeShown -bool true
"$BIN" & pid=$!
sleep 5
kill -0 "$pid" 2>/dev/null && echo "OK   app running" || bad "app did not start"
cp "$OUT/mac_clip.pptx" "$W/new.pptx"
cp "$OUT/mac_clip.pptx" "$W/new2.pptx"
cp "$OUT/mac_clip.pptx" "$W/sub/deep.pptx"
cp "$OUT/plain.pptx" "$W/plain.pptx"
for i in $(seq 1 40); do
  [ -f "$W/new_windows.pptx" ] && [ -f "$W/new2_windows.pptx" ] && [ -f "$W/sub/deep_windows.pptx" ] && break
  sleep 1
done
[ -f "$W/new_windows.pptx" ] && [ -f "$W/new2_windows.pptx" ] && echo "OK   batch of new files fixed (${i} s)" || bad "watched folder: new files"
[ -f "$W/sub/deep_windows.pptx" ] && echo "OK   subfolder fixed" || bad "watched folder: subfolder"
[ ! -e "$W/plain_windows.pptx" ] && echo "OK   no output for a presentation without Mac clips" || bad "watched folder: plain"
[ ! -e "$W/new_windows_windows.pptx" ] && echo "OK   Windows versions are not processed again" || bad "watched folder: loop"
python3 tests/check_output.py "$W/new.pptx" "$W/new_windows.pptx" 2400 > /dev/null && echo "OK   output passes all checks" || bad "watched output checks"

before=$(stat -f %m "$W/new_windows.pptx")
sleep 2
touch "$W/new.pptx"
for i in $(seq 1 40); do [ "$(stat -f %m "$W/new_windows.pptx")" != "$before" ] && break; sleep 1; done
[ "$(stat -f %m "$W/new_windows.pptx")" != "$before" ] && echo "OK   changed original -> Windows version updated (${i} s)" || bad "watched folder: update after change"

kill -0 "$pid" 2>/dev/null && echo "OK   app still running" || bad "app stopped"
kill "$pid" 2>/dev/null
defaults delete $DOMAIN 2>/dev/null || true

mkdir -p "$OUT/extracted"
unzip -o -q "$OUT/fixed.pptx" 'ppt/media/*_hr.png' -d "$OUT/extracted" || true

echo
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $fail
