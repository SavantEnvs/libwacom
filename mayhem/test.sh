#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libwacom's own test suite (built by mayhem/build.sh into mayhem/build-tests).
# exit 0 = pass. The C tests are run directly (not through `meson test`) and their TAP lines counted, so a
# neutered program yields fewer tests; known-answer probes on the built tools assert exact output.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


BT="$SRC/mayhem/build-tests"
cd "$BT"
passed=0 ; failed=0 ; skipped=0

# ---- upstream C tests (GLib TAP): count each case ---------------------------------------------
# test-tablet-validity: upstream master currently fails /tablet/realstylus for the ELAN 9008 entry
# (elan-9008.tablet resolves only the generic fallback stylus); it is skipped by name and counted.
run_tap() { # <binary> <expected-min-cases> [glib test args...]
  local bin="$1" min="$2" out ok nok
  shift 2
  [ -x "./$bin" ] || { echo "MISSING test binary $bin (build.sh bug)" >&2; failed=$((failed+1)); return; }
  out="$(./"$bin" --tap "$@" 2>&1)" || true
  ok=$(printf '%s\n' "$out" | grep -c '^ok ' || true)
  nok=$(printf '%s\n' "$out" | grep -c '^not ok ' || true)
  echo "$bin: ok=$ok not-ok=$nok (expected >= $min)"
  passed=$((passed+ok)) ; failed=$((failed+nok))
  if [ "$ok" -lt "$min" ]; then
    echo "$bin ran fewer cases than expected" >&2
    failed=$((failed+1))
  fi
}
run_tap test-load              12
run_tap test-dbverify          600
run_tap test-tablet-validity   6000 -s '/tablet/realstylus/397/04f3:43c7-ELAN9008:00'
skipped=$((skipped+1))
run_tap test-stylus-validity   1000

# ---- known-answer probes on the built tools (values from upstream's data files) -----------------
probe() { # <description> <expected fixed string> <command...>
  local desc="$1" want out
  want="$(printf '%s' "$2" | tr -s ' ')"
  shift 2
  out="$("$@" 2>&1 | tr -s ' ')" || true
  if grep -qF -- "$want" <<<"$out"; then
    passed=$((passed+1))
  else
    echo "KAT FAIL: $desc: expected: $want" >&2
    failed=$((failed+1))
  fi
}
probe "list-devices names the Intuos4 WL" \
      "- { bus: 'usb',       vid: '0x056a', pid: '0x00bc', name: 'Wacom Intuos4 WL', uniq: '' }" \
      ./list-devices
probe "list-devices lists the Bluetooth match of the Intuos4 WL" \
      "- { bus: 'bluetooth', vid: '0x056a', pid: '0x00bd', name: 'Wacom Intuos4 WL', uniq: '' }" \
      ./list-devices
probe "debug-device name" 'libwacom_get_name()                            -> "Wacom Intuos4 12x19"' \
      ./debug-device 'usb|056a|00bb'
probe "debug-device width in mm" 'libwacom_get_width_mm()                         -> 483' \
      ./debug-device 'usb|056a|00bb'
probe "debug-device height in mm" 'libwacom_get_height_mm()                        -> 305' \
      ./debug-device 'usb|056a|00bb'
probe "debug-device model name" 'libwacom_get_model_name()                      -> "PTK-1240"' \
      ./debug-device 'usb|056a|00bb'
probe "generic styli group" "- { id:  '0xfffff', name: 'General Pen' }" ./list-compatible-styli

# ---- upstream pytest suites (data file validation, ctypes API tests, SVG layouts) ----------------
export MESON_SOURCE_ROOT="$SRC" LIBWACOM_HWDB_FILE="$BT/65-libwacom.hwdb" LD_LIBRARY_PATH="$BT" \
       PYTHONDONTWRITEBYTECODE=1
for f in test_data_files test_libwacom test_svg; do
  out="$(cd "$SRC" && pytest-3 -q -p no:cacheprovider "test/$f.py" 2>&1)" || true
  tail -n 2 <<<"$out"
  p=$(grep -oE '[0-9]+ passed' <<<"$out" | tail -n1 | grep -oE '[0-9]+' || true)
  f_=$(grep -oE '[0-9]+ failed' <<<"$out" | tail -n1 | grep -oE '[0-9]+' || true)
  e_=$(grep -oE '[0-9]+ error' <<<"$out" | tail -n1 | grep -oE '[0-9]+' || true)
  s_=$(grep -oE '[0-9]+ skipped' <<<"$out" | tail -n1 | grep -oE '[0-9]+' || true)
  passed=$((passed+${p:-0})) ; failed=$((failed+${f_:-0}+${e_:-0})) ; skipped=$((skipped+${s_:-0}))
  [ "${p:-0}" -gt 0 ] || { echo "$f: no passing pytest case" >&2; failed=$((failed+1)); }
done

emit_ctrf "glib-tap+pytest" "$passed" "$failed" "$skipped"
