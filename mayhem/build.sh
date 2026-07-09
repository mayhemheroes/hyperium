#!/usr/bin/env bash
#
# mayhem/build.sh — build h2's cargo-fuzz targets as sanitized libFuzzer binaries,
# replicating OSS-Fuzz's Rust path (projects/hyperium/build.sh, the h2 half: it cds
# into h2 and runs `cargo fuzz build -O`, shipping fuzz_client, fuzz_e2e, fuzz_hpack).
#
# h2 ships its cargo-fuzz crate IN-TREE at `fuzz/` (not an additive mayhem/fuzz/
# layer). fuzz/Cargo.toml sets `[workspace] members = ["."]`, making it its own
# stand-alone cargo workspace (escaping the top-level h2 workspace) — cargo-fuzz
# only builds the fuzzed crate + deps. The binaries land at fuzz/target/....
#
# ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
# $SANITIZER_FLAGS/$CFLAGS — those don't apply to rustc), matching what OSS-Fuzz's
# `compile` sets for FUZZING_LANGUAGE=rust.
#
# LEAK DETECTION: OSS-Fuzz ships fuzz_client.options / fuzz_e2e.options with
# detect_leaks=0 (the async client/e2e harnesses leave tokio/h2 state alive at exit;
# LSan false-positives would halt fuzzing). Mayhem doesn't read .options files, so we
# bake the same setting into those two binaries as a STRONG `__asan_default_options`
# symbol (a weak one loses to the sanitizer runtime's default and LSan then aborts
# under Mayhem's tracer). fuzz_hpack keeps full leak detection — exact OSS-Fuzz parity.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity
# even though the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (debuginfo=2 for compact line tables) and
# wires in the cc-wrapper that prepends a DWARF3 anchor object as the FIRST object in
# every link — this makes the -m1 readelf check in verify-repo see DWARF v3 even though
# the precompiled ASan runtime CUs (from librustc-nightly_rt.asan.a) remain DWARF v5
# deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself by default,
# but we set it explicitly so behavior is pinned and visible. `--cfg fuzzing` matches
# libfuzzer-sys; force-frame-pointers aids ASan stack traces.
BASE_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_DIR="fuzz"

# Strong __asan_default_options object for the detect_leaks=0 targets (idempotent).
ASAN_OPTS_OBJ="/tmp/mayhem-asan-opts.o"
printf 'const char *__asan_default_options(void) { return "detect_leaks=0"; }\n' > /tmp/mayhem-asan-opts.c
clang -c -fPIC -gdwarf-3 /tmp/mayhem-asan-opts.c -o "$ASAN_OPTS_OBJ"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="

# target:extra-link — every OSS-Fuzz-shipped h2 harness (ship-ALL per SPEC §6.2 item 12).
TARGETS=(
  "fuzz_hpack:"
  "fuzz_client:leak0"
  "fuzz_e2e:leak0"
)

for spec in "${TARGETS[@]}"; do
  target="${spec%%:*}"; mode="${spec#*:}"
  flags="$BASE_RUSTFLAGS"
  [ "$mode" = "leak0" ] && flags="$flags -Clink-arg=$ASAN_OPTS_OBJ"
  echo "--- building fuzz target: $target (RUSTFLAGS=$flags) ---"
  ( cd "$SRC" && RUSTFLAGS="$flags" cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$target" )
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$target"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$target"
  echo "built /mayhem/$target"
done

# Pre-build h2's own test suite with the project's NORMAL flags (no sanitizer) so
# mayhem/test.sh only RUNS it (same RUSTFLAGS there → no recompile at test time).
echo "=== pre-building the h2 test suite (normal flags) ==="
( cd "$SRC" && RUSTFLAGS="" cargo test -p h2-tests --tests --no-run --jobs "$MAYHEM_JOBS" )
( cd "$SRC" && RUSTFLAGS="" cargo test -p h2 --lib --no-run --jobs "$MAYHEM_JOBS" )

echo "build.sh complete:"
ls -la /mayhem/fuzz_hpack /mayhem/fuzz_client /mayhem/fuzz_e2e 2>&1 || true
