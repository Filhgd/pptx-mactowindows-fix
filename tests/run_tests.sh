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

step "image at the 5000 px cap"
# Picture on slide 1 made 24976468 EMU wide: scaling down to the cap gives 5000.000000000001, which must still work.
python3 - "$OUT" <<'PY'
import re, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(f"{out}/mac_clip.pptx") as z, zipfile.ZipFile(f"{out}/wide.pptx", "w", zipfile.ZIP_DEFLATED) as w:
    for i in z.infolist():
        data = z.read(i)
        if i.filename == "ppt/slides/slide1.xml":   # slide 2 shows it smaller, slide 3 another image
            data = re.sub(rb'<a:ext cx="\d+"', b'<a:ext cx="24976468"', data)
        w.writestr(i, data)
PY
"$BIN" --fix "$OUT/wide.pptx" "$OUT/wide_out.pptx" || bad "image at the cap: fix exited with an error"
python3 tests/check_output.py "$OUT/wide.pptx" "$OUT/wide_out.pptx" 5000 > /dev/null && echo "OK   rendered at 5000 px" || bad "image at the cap: output checks"

step "hostile files are refused without crashing or hanging"
python3 - "$OUT" <<'PY'
import re, struct, sys, zipfile
out = sys.argv[1]
src = f"{out}/mac_clip.pptx"
# Picture width with 400 digits: parses as infinity.
with zipfile.ZipFile(src) as z, zipfile.ZipFile(f"{out}/evil_cx.pptx", "w", zipfile.ZIP_DEFLATED) as w:
    for i in z.infolist():
        data = z.read(i)
        if i.filename.startswith("ppt/slides/slide"):
            data = re.sub(rb'<a:ext cx="\d+"', b'<a:ext cx="' + b"9" * 400 + b'"', data)
        w.writestr(i, data)
# Central directory listed twice: every part shares its bytes with another entry.
b = open(src, "rb").read()
e = b.rindex(b"PK\x05\x06")
count, size, off = struct.unpack("<HII", b[e + 10:e + 20])
cd = b[off:off + size]
eocd = b[e:e + 8] + struct.pack("<HHII", 2 * count, 2 * count, 2 * size, off) + b"\0\0"
open(f"{out}/evil_overlap.pptx", "wb").write(b[:off] + cd + cd + eocd)
# First part claims to unpack to about 4.3 GB: far more than the file itself.
bomb = bytearray(b)
bomb[off + 24:off + 28] = struct.pack("<I", 0xFFFF_FFF0)
open(f"{out}/evil_bomb.pptx", "wb").write(bomb)
PY
"$BIN" --fix "$OUT/evil_cx.pptx" "$OUT/evil_cx_out.pptx"; code=$?
[ $code -eq 0 ] && echo "OK   huge picture width handled" || bad "huge picture width: exit $code"
r=$("$BIN" --fix "$OUT/evil_overlap.pptx" "$OUT/evil_overlap_out.pptx" 2>&1); echo "$r"
echo "$r" | grep -q "overlapping parts" && echo "OK   overlapping parts refused" || bad "overlapping parts not refused"
r=$("$BIN" --fix "$OUT/evil_bomb.pptx" "$OUT/evil_bomb_out.pptx" 2>&1); echo "$r"
echo "$r" | grep -q "far more than their own size" && [ ! -e "$OUT/evil_bomb_out.pptx" ] && echo "OK   zip bomb refused" || bad "zip bomb not refused"
rm -f "$OUT/evil_fifo.pptx"; mkfifo "$OUT/evil_fifo.pptx"
perl -e 'alarm 10; exec @ARGV' "$BIN" --fix "$OUT/evil_fifo.pptx" "$OUT/evil_fifo_out.pptx"; code=$?
[ $code -eq 1 ] && echo "OK   FIFO refused" || bad "FIFO: exit $code (142 = hung)"
rm -f "$OUT/evil_fifo.pptx"
ln -sf /dev/zero "$OUT/evil_zero.pptx"
perl -e 'alarm 10; exec @ARGV' "$BIN" --fix "$OUT/evil_zero.pptx" "$OUT/evil_zero_out.pptx"; code=$?
[ $code -eq 1 ] && echo "OK   link to /dev/zero refused" || bad "link to /dev/zero: exit $code (142 = hung)"
rm -f "$OUT/evil_zero.pptx"

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
defaults write $DOMAIN onboardingV2Done -bool true
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

step "update check: version comparison"
cmp() { r=$("$BIN" --compare "$1" "$2"); [ "$r" = "$3" ] && echo "OK   $1 vs $2: $r" || bad "compare $1 vs $2 gave '$r', expected '$3'"; }
cmp 1.1.0 1.0.1 newer
cmp v1.10.0 1.9.9 newer
cmp 2.0 1.99.99 newer
cmp 1.0.9 1.1.0 "not newer"
cmp 1.1 1.1.0 "not newer"
cmp v1.1.0 1.1.0 "not newer"

step "update check: a newer release"
cat > "$OUT/release_new.json" <<'JSON'
{"tag_name": "v9.9.9", "html_url": "https://github.com/Filhgd/pptx-mactowindows-fix/releases/tag/v9.9.9",
 "body": "### New\n- **Faster** fixing\n- Update check",
 "assets": [{"name": "PPTX-MacToWindows-Fix-macOS.zip", "browser_download_url": "https://example.com/PPTX-MacToWindows-Fix-macOS.zip"}]}
JSON
r=$(PPTXFIX_RELEASES_URL="file://$PWD/$OUT/release_new.json" "$BIN" --check-update); echo "$r"
echo "$r" | grep -q "latest 9.9.9: update available" && echo "OK   update detected" || bad "newer release not detected"
echo "$r" | grep -q "download: https://example.com/PPTX-MacToWindows-Fix-macOS.zip" && echo "OK   points to the zip" || bad "download link"
echo "$r" | grep -q "• Faster fixing" && echo "OK   release notes cleaned up" || bad "release notes"

step "update check: an older release"
cat > "$OUT/release_old.json" <<'JSON'
{"tag_name": "v1.0.0", "html_url": "https://github.com/Filhgd/pptx-mactowindows-fix/releases/tag/v1.0.0", "body": "", "assets": []}
JSON
r=$(PPTXFIX_RELEASES_URL="file://$PWD/$OUT/release_old.json" "$BIN" --check-update); echo "$r"
echo "$r" | grep -q "up to date" && echo "OK   no update offered" || bad "older release offered as update"

step "update check: real GitHub (information only)"
"$BIN" --check-update || echo "WARN could not reach GitHub from the runner"

step "update check: the running app finds an update by itself"
DOMAIN=be.haegdorens.pptxmactowindowsfix
defaults delete $DOMAIN 2>/dev/null || true
defaults write $DOMAIN welcomeShown -bool true
defaults write $DOMAIN onboardingV2Done -bool true
PPTXFIX_RELEASES_URL="file://$PWD/$OUT/release_new.json" "$BIN" & pid=$!
for i in $(seq 1 40); do [ "$(defaults read $DOMAIN notifiedVersion 2>/dev/null)" = "9.9.9" ] && break; sleep 1; done
[ "$(defaults read $DOMAIN notifiedVersion 2>/dev/null)" = "9.9.9" ] && echo "OK   update announced after ${i} s" || bad "automatic update check"
[ -n "$(defaults read $DOMAIN lastUpdateCheck 2>/dev/null)" ] && echo "OK   check time saved (next check in a day)" || bad "lastUpdateCheck"
kill "$pid" 2>/dev/null
defaults delete $DOMAIN 2>/dev/null || true

step "window screenshots (light and dark)"
"$BIN" --render-ui "$OUT/ui"
count=$(ls "$OUT/ui"/*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$count" = "14" ] && echo "OK   14 screenshots" || bad "expected 14 screenshots, got $count"

step "app starts with the welcome screen on first launch"
defaults delete $DOMAIN 2>/dev/null || true
"$BIN" & pid=$!
sleep 6
kill -0 "$pid" 2>/dev/null && echo "OK   running with the welcome screen" || bad "app stopped on first launch"
kill "$pid" 2>/dev/null
defaults delete $DOMAIN 2>/dev/null || true

mkdir -p "$OUT/extracted"
unzip -o -q "$OUT/fixed.pptx" 'ppt/media/*_hr.png' -d "$OUT/extracted" || true

echo
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $fail
