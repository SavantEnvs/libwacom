#!/usr/bin/env bash
#
# mayhem/build.sh — build libwacom's fuzz harnesses (sanitized) and its test suite (normal flags).
# Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline (meson has no downloads here).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
BF="$SRC/mayhem/build-fuzz"
BT="$SRC/mayhem/build-tests"

# meson refuses a plain `setup` on an already configured directory.
setup() { # <builddir> <extra meson args...>
  local dir="$1"; shift
  if [ -f "$dir/build.ninja" ]; then set -- --reconfigure "$@"; fi
  meson setup "$dir" "$@"
}

# 1) The project with the sanitizers and DWARF 3. -fsanitize=fuzzer-no-link puts SanCov on the library
#    itself (the harness TU only gets it through $LIB_FUZZING_ENGINE), also when SANITIZER_FLAGS is empty.
CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
LDFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" \
  setup "$BF" -Dtests=disabled
# Only the library's objects are needed (the shared library and tools are not linked here).
mapfile -t OBJ_TARGETS < <(ninja -C "$BF" -t targets all | sed -n 's/^\(libwacom\.so[^:]*\.p\/[^:]*\.c\.o\):.*/\1/p')
[ "${#OBJ_TARGETS[@]}" -gt 0 ] || { echo "no libwacom object targets in $BF" >&2; exit 1; }
ninja -C "$BF" -j"$MAYHEM_JOBS" "${OBJ_TARGETS[@]}"

# The harnesses call the public API of the library's own objects, linked statically so the fuzzed
# code is instrumented in the fuzzer binary (the shared build is only used to get the objects).
LIB_OBJS=("$BF"/libwacom.so*.p/*.c.o)
[ -e "${LIB_OBJS[0]}" ] || { echo "no libwacom objects in $BF" >&2; exit 1; }
DEPS_CFLAGS="$(pkg-config --cflags glib-2.0 gudev-1.0 libevdev)"
DEPS_LIBS="$(pkg-config --libs glib-2.0 gudev-1.0 libevdev)"

# Fixed, valid files that sit next to the fuzzed one (embedded: a target must not read image paths).
embed() { od -An -v -tx1 "$1" | sed 's/ \([0-9a-f][0-9a-f]\)/0x\1,/g' > "$BF/$2"; }
embed data/wacom.stylus                    embed_wacom_stylus.h
embed data/lenovo.stylus                   embed_lenovo_stylus.h
embed data/wacom-intuos4-6x9-wl.tablet     embed_intuos4_tablet.h
embed data/wacom-cintiq-pro-13.tablet      embed_cintiq_tablet.h

# 2) Leak detection off at build time, linked into every binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$BF/lsan_off.o"

for h in fuzz_tablet fuzz_stylus; do
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      -I"$SRC/mayhem" -I"$SRC/libwacom" -I"$SRC/include" -I"$BF" $DEPS_CFLAGS \
      "mayhem/$h.c" "${LIB_OBJS[@]}" "$BF/lsan_off.o" $DEPS_LIBS -o "$SRC/$h"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
      -I"$SRC/mayhem" -I"$SRC/libwacom" -I"$SRC/include" -I"$BF" $DEPS_CFLAGS \
      "$STANDALONE_FUZZ_MAIN" "mayhem/$h.c" "${LIB_OBJS[@]}" "$BF/lsan_off.o" $DEPS_LIBS -o "$SRC/$h-standalone"
done

# 3) The upstream test suite and tools with the project's NORMAL flags (no sanitizers, no -gdwarf-3).
#    test.sh only runs them.
(
  export CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  setup "$BT" -Dtests=enabled
)
ninja -C "$BT" -j"$MAYHEM_JOBS"
