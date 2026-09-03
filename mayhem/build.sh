#!/usr/bin/env bash
#
# mayhem/build.sh — build SDL_sound's fuzz harness(es) + a clean test build.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract (CC/CXX/LIB_FUZZING_ENGINE/
# SANITIZER_FLAGS/DEBUG_FLAGS/STANDALONE_FUZZ_MAIN/SRC). SDL3 (libsdl3-dev) is installed by
# the Dockerfile as root before this runs, so the build is fully offline-resolvable.
#
# Layout produced:
#   /mayhem/fuzz_samplefrommem             libFuzzer target (sanitized lib + harness)
#   /mayhem/fuzz_samplefrommem-standalone  run-once reproducer (no libFuzzer runtime)
#   /mayhem/sdlsound_selftest              functional test runner (NORMAL flags) for test.sh
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Apply local source fixes for fuzzer-found defects. Kept as additive patches under
# mayhem/patches/ so src/ stays a pristine upstream mirror (the sync cron won't conflict).
# Idempotent: a patch that already applied (reverse-check succeeds) is skipped, so build.sh
# re-runs cleanly in the same image.
git config --global --add safe.directory "$SRC" 2>/dev/null || true
for p in "$SRC"/mayhem/patches/*.patch; do
    [ -f "$p" ] || continue
    if git apply --reverse --check "$p" 2>/dev/null; then
        echo "patch already applied, skipping: $(basename "$p")"
    else
        echo "applying patch: $(basename "$p")"
        git apply "$p"
    fi
done

SDL3_CFLAGS="$(pkg-config --cflags sdl3)"
SDL3_LIBS="$(pkg-config --libs sdl3)"

# ---------------------------------------------------------------------------
# 1) Build the SDL_sound library ITSELF with $SANITIZER_FLAGS + $DEBUG_FLAGS so the
#    FUZZED code (the decoders) is instrumented and carries DWARF<4 symbols. Static lib,
#    no tests/docs/shared — just the instrumented archive we link the harness against.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-fuzz"
cmake -S "$SRC" -B "$SRC/build-fuzz" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -DSDLSOUND_BUILD_STATIC=ON \
    -DSDLSOUND_BUILD_SHARED=OFF \
    -DSDLSOUND_BUILD_TEST=OFF \
    -DSDLSOUND_BUILD_DOCS=OFF \
    -DSDLSOUND_INSTALL=OFF
# NOTE: -fsanitize=fuzzer-no-link instruments the LIBRARY (bundled decoders: dr_flac/dr_mp3/
# stb_vorbis/libmodplug/timidity) with SanitizerCoverage so libFuzzer gets coverage feedback
# from inside the codecs. Without it only the harness is instrumented (cov stuck at ~4 edges).
cmake --build "$SRC/build-fuzz" -j"$MAYHEM_JOBS" --target SDL3_sound-static

SDLSOUND_A="$(find "$SRC/build-fuzz" -name 'libSDL3_sound*.a' | head -n1)"
[ -n "$SDLSOUND_A" ] || { echo "ERROR: sanitized libSDL3_sound static archive not found" >&2; exit 1; }
echo "sanitized lib: $SDLSOUND_A"

# ---------------------------------------------------------------------------
# 2) Compile the harness TWICE: once with the fuzzing engine (the fuzzer), once with the
#    standalone run-once driver (a non-fuzzer reproducer). Both link the sanitized lib + SDL3
#    and respect $SANITIZER_FLAGS + $DEBUG_FLAGS.
# ---------------------------------------------------------------------------
HARNESS="$SRC/mayhem/fuzz_samplefrommem.c"
INCLUDES="-I$SRC/include $SDL3_CFLAGS"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$HARNESS" $INCLUDES \
    "$SDLSOUND_A" $SDL3_LIBS -lm \
    -o /mayhem/fuzz_samplefrommem

$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$STANDALONE_FUZZ_MAIN" "$HARNESS" $INCLUDES \
    "$SDLSOUND_A" $SDL3_LIBS -lm \
    -o /mayhem/fuzz_samplefrommem-standalone

# ---------------------------------------------------------------------------
# 3) Build the functional TEST runner with the project's NORMAL flags (clean, independent of the
#    sanitized build). It decodes the bundled corpus via the SDL_sound API and asserts known
#    properties — see mayhem/test.sh / mayhem/sdlsound_selftest.c. test.sh only RUNS it.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-test"
cmake -S "$SRC" -B "$SRC/build-test" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DSDLSOUND_BUILD_STATIC=ON \
    -DSDLSOUND_BUILD_SHARED=OFF \
    -DSDLSOUND_BUILD_TEST=OFF \
    -DSDLSOUND_BUILD_DOCS=OFF \
    -DSDLSOUND_INSTALL=OFF
cmake --build "$SRC/build-test" -j"$MAYHEM_JOBS" --target SDL3_sound-static

SDLSOUND_TEST_A="$(find "$SRC/build-test" -name 'libSDL3_sound*.a' | head -n1)"
[ -n "$SDLSOUND_TEST_A" ] || { echo "ERROR: test libSDL3_sound static archive not found" >&2; exit 1; }

$CC -O2 $COVERAGE_FLAGS \
    "$SRC/mayhem/sdlsound_selftest.c" -I"$SRC/include" $SDL3_CFLAGS \
    "$SDLSOUND_TEST_A" $SDL3_LIBS -lm \
    -o /mayhem/sdlsound_selftest

echo "build.sh OK: $(ls -1 /mayhem/fuzz_samplefrommem /mayhem/fuzz_samplefrommem-standalone /mayhem/sdlsound_selftest)"
