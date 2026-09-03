#!/usr/bin/env bash
#
# mayhem/test.sh — RUN SDL_sound's functional known-answer test (built by mayhem/build.sh as
# /mayhem/sdlsound_selftest). It decodes the bundled corpus through the public API and asserts
# observable results (decoder selected, sane format, non-trivial PCM decoded, EOF, no error).
# Does NOT compile. Emits a CTRF summary and exits non-zero iff any case failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

RUNNER=/mayhem/sdlsound_selftest
if [ ! -x "$RUNNER" ]; then
  echo "ERROR: $RUNNER missing — mayhem/build.sh did not produce the test runner" >&2
  emit_ctrf "sdlsound-selftest" 0 1 0
  exit 1
fi

# Run the known-answer test against the shipped corpus; capture output to parse counts.
export SDL_AUDIODRIVER=dummy
out="$("$RUNNER" "$SRC/mayhem/sdl-sound-fuzzer/testsuite" 2>&1)"
rc=$?
echo "$out"

# Parse "SELFTEST passed=P failed=F total=T"
line="$(printf '%s\n' "$out" | grep -E '^SELFTEST ' | tail -n1)"
passed="$(printf '%s\n' "$line" | sed -nE 's/.*passed=([0-9]+).*/\1/p')"
failed="$(printf '%s\n' "$line" | sed -nE 's/.*failed=([0-9]+).*/\1/p')"

if [ -z "$passed" ] || [ -z "$failed" ]; then
  # Runner crashed or produced no summary — treat as a failure.
  echo "ERROR: could not parse selftest summary (rc=$rc)" >&2
  emit_ctrf "sdlsound-selftest" 0 1 0
  exit 1
fi

emit_ctrf "sdlsound-selftest" "$passed" "$failed" 0
