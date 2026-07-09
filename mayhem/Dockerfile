# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz). Builds ON TOP of the
# org C/C++ base (ghcr.io/mayhemheroes/base), adding a pinned Rust toolchain +
# cargo-fuzz under /opt/toolchains/rust, then runs mayhem/build.sh.
#
# h2 is hyperium's HTTP/2 protocol crate. Its cargo-fuzz crate ships IN-TREE at
# `fuzz/` (its own stand-alone cargo workspace — `[workspace] members = ["."]` in
# fuzz/Cargo.toml keeps it out of the top-level h2 workspace), with three targets:
# fuzz_client, fuzz_e2e, fuzz_hpack — exactly what OSS-Fuzz's projects/hyperium
# build.sh builds from the h2 repo.
#
# WHY a Rust-specific template (SPEC §6.2 items 8/9, §6.5):
#   The Rust toolchain and its package cache (the cargo registry) are NOT in the
#   base. We install them at a FIXED, $HOME-independent prefix (/opt/toolchains/rust)
#   and pin CARGO_HOME/RUSTUP_HOME there as ENV. That matters twice:
#     - the task tier can lock the whole toolchain at one path (§4/§5); and
#     - the cargo registry the FIRST (online) build populates is found again — by
#       the SAME absolute CARGO_HOME — when the PATCH RL tier re-runs build.sh with
#       NO network. (A cache left at the default ~/.cargo would vanish under the
#       re-run identity's $HOME and the offline build would die resolving crates.)
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t hyperium-commit:test .

# The org base, pinned to a fixed YEAR-MONTH tag (pin by digest in production).
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# Pin the channel by DATE: -Zsanitizer=address (the OSS-Fuzz Rust ASan path) needs
# nightly, and a dated nightly keeps the build reproducible. h2's MSRV is 1.63 /
# edition 2021 — any recent nightly satisfies that; pin the same dated nightly used
# by the other Rust integrations (tokio) for consistency.
ARG RUST_TOOLCHAIN=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_TOOLCHAIN}"; \
    rustup component add rust-src --toolchain "${RUST_TOOLCHAIN}"; \
    cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked; \
    rm -f /tmp/rustup-init.sh; \
    rustc --version; cargo --version; cargo fuzz --version; \
    # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
    # read the toolchain and read/refresh the cargo registry cache, so hand the whole
    # prefix to 2000. (Task-tier lockdown re-locks it per type; PATCH keeps it usable.)
    chown -R 2000:2000 /opt/toolchains/rust

# DWARF<4 gate workaround for Rust/cargo-fuzz (§6.2 item 10).
# cargo-fuzz links the Rust nightly ASan runtime archive (librustc-nightly_rt.asan.a)
# via --whole-archive, and that archive's objects (compiled with DWARF v5) land FIRST
# in .debug_info before any user/std CUs. `-Z dwarf-version=3` only controls rustc's
# OWN CUs — it can't retroactively lower the precompiled runtime, and combining it with
# `-Zsanitizer=address` has caused compiler ICEs on some nightlies. Instead: compile a
# tiny empty stub with `clang -gdwarf-3` and inject it as the FIRST object in every link
# via a cc-wrapper (-Clinker=...). Since .debug_info CUs appear in linker-argument order,
# the anchor's DWARF3 CU becomes offset 0 — the one verify-repo's `readelf -m1` reads.
RUN set -eux; \
    mkdir -p /opt/mayhem-dwarf3-anchor; \
    printf 'void __mayhem_dwarf3_anchor(void) __attribute__((visibility("hidden"),used));\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
      > /opt/mayhem-dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/mayhem-dwarf3-anchor/anchor.c \
      -o /opt/mayhem-dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/mayhem-dwarf3-anchor /opt/mayhem-dwarf3-anchor/anchor.o \
               /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/mayhem-dwarf3-anchor/anchor.o | grep -m1 Version:)"

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history — the grader uses it) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz targets.
RUN bash mayhem/build.sh

# Run h2's own test suite at build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
