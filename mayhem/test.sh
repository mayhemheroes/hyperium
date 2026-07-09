#!/usr/bin/env bash
#
# mayhem/test.sh — RUN h2's own assertion-based test suites (`cargo test`) and emit a
# CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: h2 ships an extensive integration suite (tests/h2-tests, driven
# by the h2-support mock transport) plus in-crate unit tests that assert concrete
# protocol behavior — exact frame bytes, HPACK encodings, stream-state transitions,
# error codes (assert_eq! on known-answer values, not just "didn't crash"). A no-op /
# "exit(0)" patch to the fuzzed code (the h2 client/server/hpack paths) CANNOT pass
# this — the asserted frames/encodings would no longer match. This script only RUNS
# the suites via `cargo test` (pre-built by mayhem/build.sh with the same flags);
# it never builds fuzz targets.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

PASSED=0; FAILED=0; IGNORED=0
OVERALL_RC=0

run_suite() {
  local pkg="$1"; shift
  echo "=== running cargo test -p $pkg $* ==="
  local out rc
  out="$(cd "$SRC" && RUSTFLAGS="" cargo test -p "$pkg" --no-fail-fast --jobs "$MAYHEM_JOBS" "$@" 2>&1)"
  rc=$?
  echo "$out"
  [ "$rc" -eq 0 ] || OVERALL_RC=1

  # libtest prints one line per test binary:
  #   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
  while read -r p f i; do
    PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
  done < <(printf '%s\n' "$out" \
    | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')
}

# The integration suite (mock-transport protocol tests) + the h2 crate's unit tests.
run_suite h2-tests --tests
run_suite h2 --lib

if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code(s) (overall_rc=$OVERALL_RC)" >&2
  if [ "$OVERALL_RC" -eq 0 ]; then emit_ctrf "cargo-test" 1 0 0; exit 0; fi
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
