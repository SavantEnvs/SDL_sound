#!/usr/bin/env bash
#
# mayhem/build.sh — build SDL_sound's fuzz harness (the libFuzzer target + its standalone reproducer).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract (CC/CXX/LIB_FUZZING_ENGINE/
# SANITIZER_FLAGS/DEBUG_FLAGS/STANDALONE_FUZZ_MAIN/SRC). SDL3 (libsdl3-dev) is installed by
# the Dockerfile as root before this runs, so the build is fully offline-resolvable.
#
# Layout produced:
#   /mayhem/fuzz_samplefrommem             libFuzzer target (sanitized lib + harness)
#   /mayhem/fuzz_samplefrommem-standalone  run-once reproducer (no libFuzzer runtime)
# Both sanitized binaries link mayhem/lsan_off.c (build-time LeakSanitizer off-switch).
#
# No separate test build. mayhem/test.sh's known-answer test runs /mayhem/fuzz_samplefrommem itself,
# the binary PoV replay runs. This is a deliberate exception to the usual advice that the test build
# keeps the project's normal flags, for the reason fast_rsync's oracle shares the fuzz build (#1122,
# #1460). A test runner built with other flags (the old Release sdlsound_selftest) is a different
# program. A patch could gate a decoder on __has_feature(address_sanitizer), __OPTIMIZE__ or
# coverage_sanitizer and neuter it only in the graded binary while test.sh still passed.
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

SDL3_CFLAGS="$(pkg-config --cflags sdl3)"
SDL3_LIBS="$(pkg-config --libs sdl3)"

# ---------------------------------------------------------------------------
# 1) Build the SDL_sound library ITSELF with $SANITIZER_FLAGS + $DEBUG_FLAGS so the
#    FUZZED code (the decoders) is instrumented and carries DWARF<4 symbols. Static lib,
#    no tests/docs/shared — just the instrumented archive we link the harness against.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-fuzz"
# $COVERAGE_FLAGS is empty by default (no effect). A source-coverage measurement build
# (--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping", never used for fuzzing or
# grading) instruments the library and the harness, so test.sh's runs of the target measure the suite.
cmake -S "$SRC" -B "$SRC/build-fuzz" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $COVERAGE_FLAGS" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $COVERAGE_FLAGS" \
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

# LeakSanitizer off at build time (mayhem/lsan_off.c, SPEC §6.2 item 15); ASan+UBSan stay on.
# Compiled with the same sanitizer flags and linked into BOTH sanitized binaries below.
LSAN_OFF_OBJ="$SRC/build-fuzz/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $COVERAGE_FLAGS \
    "$HARNESS" $INCLUDES \
    "$SDLSOUND_A" "$LSAN_OFF_OBJ" $SDL3_LIBS -lm \
    -o /mayhem/fuzz_samplefrommem

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $COVERAGE_FLAGS \
    "$STANDALONE_FUZZ_MAIN" "$HARNESS" $INCLUDES \
    "$SDLSOUND_A" "$LSAN_OFF_OBJ" $SDL3_LIBS -lm \
    -o /mayhem/fuzz_samplefrommem-standalone

echo "build.sh OK: $(ls -1 /mayhem/fuzz_samplefrommem /mayhem/fuzz_samplefrommem-standalone)"
