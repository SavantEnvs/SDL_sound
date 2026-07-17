#!/usr/bin/env bash
#
# mayhem/test.sh - known-answer test of SDL_sound's decoders, run through the graded binary.
#
# Each case in mayhem/sdl-sound-kat.expected names one real file (one per decoder family) shipped in
# mayhem/sdl-sound-fuzzer/testsuite/. For each case test.sh runs /mayhem/fuzz_samplefrommem, the
# libFuzzer target that PoV replay runs, built by mayhem/build.sh with the graded flags, on that one
# file with MAYHEM_SDLSOUND_KAT set. It then checks the report the harness writes (decoder, format,
# channels, rate, EOF reached, no error flag) and the decoded PCM that test.sh measures itself: exact
# PCM length and sha256 for every case, lossless (WAV, AU, FLAC) and lossy (Vorbis, MPEG audio layers
# I/II) alike. The lossy decoders' float output is bit-identical from run to run and with glibc's
# FMA/AVX code paths masked off (GLIBC_TUNABLES=glibc.cpu.hwcaps), so an exact hash is deterministic;
# a length-only check would pass a decoder that emits garbage of the right length.
# The verdict is test.sh's own comparison. It parses no summary or tally from the tested process's
# output (#831 HARNESS-2). The program under test is the graded build itself, so a build-flavor
# difference cannot change what test.sh checks and leave the PoVs alone (#1460).
# A case fails when it is missing, duplicated or malformed in the report, so a no-op program fails.
# The tested program runs as the same uid as test.sh and can write /mayhem and the report directory,
# so test.sh mitigates (it cannot fully prevent) tampering by the program under test:
#   - the whole script is one function, main, called from the last line together with exit
#     (`main "$@"; exit $?`): bash has parsed every line before the first target runs, so a
#     program that rewrites mayhem/test.sh on disk cannot change what this run executes (bash
#     otherwise reads a script lazily, as it executes it);
#   - test.sh reads the case table into memory before any target runs;
#   - emit_ctrf restores owner rwx on the report's directory and removes whatever is at the report
#     path (rm -rf) before writing it, so a planted read-only report, a read-only report directory
#     or a directory at the report path does not survive, and it never writes through a planted file.
#   - each target runs without CTRF_REPORT in its environment. This is hygiene, not a protection:
#     the target can read the path from /proc/$PPID/environ, and the report sits in $TMPDIR anyway.
# NOT closed here (rlenv side): a same-uid target can plant a passing report and then SIGKILL
# test.sh before emit_ctrf runs, or leave a process behind that rewrites the report after test.sh
# writes it. rlenv v3.11.0 takes pass/fail only from the CTRF file, so only an rlenv-side fix
# (honour test.sh's exit status or signal death, or capture the report through an inherited fd)
# closes that channel.
# To regenerate the expected file from the pinned upstream baseline, run this script in the
# unpatched commit image and copy the "actual:" lines it prints.
# Does NOT compile. Emits a CTRF summary and exits non-zero iff any case failed.
set -uo pipefail

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  local out="${CTRF_REPORT:-$SRC/ctrf-report.json}"
  # The tested program runs as the same uid: it may have planted a read-only report, a directory, or
  # made the report's directory read-only. Restore owner rwx (u+rwx, never a fixed mode: without
  # CTRF_REPORT the directory is $SRC) and remove whatever is at the path before writing.
  chmod u+rwx -- "$(dirname -- "$out")" 2>/dev/null
  rm -rf -- "$out"
  cat > "$out" <<JSON
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

# value of key $1 in report $2: printed only when the key occurs exactly once
kv() { awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); n++ } END { if (n == 1) print v; else exit 1 }' "$2"; }

main() {
  [ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
  cd "$SRC"

  TOOL=sdlsound-kat
  TARGET=/mayhem/fuzz_samplefrommem
  EXPECTED="$SRC/mayhem/sdl-sound-kat.expected"
  DATA="$SRC/mayhem/sdl-sound-fuzzer/testsuite"
  NCASES=6   # cases in $EXPECTED; a shorter or unreadable list fails

  # Snapshot the case table into memory BEFORE any target runs: the program under test runs as the
  # runner, which can write /mayhem, so a lazily re-read table could be rewritten mid-run.
  CASES=()
  [ -r "$EXPECTED" ] && mapfile -t CASES < <(grep -vE '^[[:space:]]*(#|$)' "$EXPECTED")
  n_listed=${#CASES[@]}
  if [ ! -x "$TARGET" ] || [ "$n_listed" -ne "$NCASES" ]; then
    echo "ERROR: $TARGET missing (build.sh bug) or $EXPECTED lists $n_listed of $NCASES cases" >&2
    emit_ctrf "$TOOL" 0 "$NCASES"
    exit 1
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/sdlsound-kat.XXXXXX")" || { emit_ctrf "$TOOL" 0 "$NCASES"; exit 1; }
  trap 'rm -rf "$work"' EXIT

  passed=0; failed=0
  for line in "${CASES[@]}"; do
    read -r file e_dec e_fmt e_ch e_rate e_bytes e_sum extra <<< "$line"
    rep="$work/kat"; rm -f "$rep" "$rep.pcm"
    env -u CTRF_REPORT SDL_AUDIODRIVER=dummy MAYHEM_SDLSOUND_KAT="$rep" \
      "$TARGET" -artifact_prefix="$work/" "$DATA/$file" > "$work/log" 2>&1 < /dev/null
    rc=$?
    why=""
    if [ -n "${extra:-}" ] || [ -z "${e_sum:-}" ]; then
      why="malformed line in $EXPECTED"
    elif [ "$rc" -ne 0 ]; then
      why="target exited with status $rc"
    elif [ ! -f "$rep" ] || [ ! -f "$rep.pcm" ]; then
      why="no known-answer report (no decoder accepted the input)"
    else
      a_dec=$(kv decoder "$rep") && a_fmt=$(kv format "$rep") && a_ch=$(kv channels "$rep") &&
        a_rate=$(kv rate "$rep") && a_eof=$(kv eof "$rep") && a_err=$(kv error "$rep") ||
        why="malformed known-answer report"
      if [ -z "$why" ]; then
        a_bytes=$(stat -c %s "$rep.pcm")
        a_sum=$(sha256sum "$rep.pcm" | cut -d' ' -f1)
        echo "actual: $file $a_dec $a_fmt $a_ch $a_rate $a_bytes $a_sum"
        if [ "$a_dec $a_fmt $a_ch $a_rate" != "$e_dec $e_fmt $e_ch $e_rate" ]; then
          why="decoder/format/channels/rate = $a_dec $a_fmt $a_ch $a_rate, expected $e_dec $e_fmt $e_ch $e_rate"
        elif [ "$a_eof" != 1 ] || [ "$a_err" != 0 ]; then
          why="eof=$a_eof error=$a_err (expected EOF without error)"
        elif [ "$a_bytes" != "$e_bytes" ] || [ "$a_sum" != "$e_sum" ]; then
          why="decoded PCM ($a_bytes bytes, sha256 $a_sum) differs from the expected $e_bytes bytes, sha256 $e_sum"
        fi
      fi
    fi
    if [ -z "$why" ]; then
      echo "PASS $file"
      passed=$(( passed + 1 ))
    else
      echo "FAIL $file: $why"
      tail -n 5 "$work/log" | sed 's/^/    /'
      failed=$(( failed + 1 ))
    fi
  done

  # Every listed case ran exactly once, so the two counts must add up to the listed total.
  if [ $(( passed + failed )) -ne "$NCASES" ]; then
    failed=$(( NCASES - passed ))
  fi
  emit_ctrf "$TOOL" "$passed" "$failed"
}

# Parse-then-run: this line is read whole before main starts, and nothing after it is ever read.
main "$@"; exit $?
