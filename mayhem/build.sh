#!/usr/bin/env bash
#
# mayhem/build.sh — build winnow's libFuzzer fuzz target as a sanitized binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), build the KAT oracle
# probe, and precompile the project's test suite for mayhem/test.sh to RUN.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache (CARGO_NET_OFFLINE=true is
#     exported by the runtime), so we do NOT hard-code `--offline` here.
#   - winnow commits a complete root Cargo.lock that covers the in-workspace
#     fuzz/ crate too, so no lockfile generation / dep pinning is needed at all.
#
# winnow's fuzz/ crate IS a root-workspace member (root Cargo.toml: members =
# ["fuzz"]), so `cargo fuzz build` writes the binary to the ROOT
# target/<triple>/release/, NOT fuzz/target/... (workspace-membership rule).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# The toolchain the Dockerfile installed. Referenced EXPLICITLY (+$RUST_CHANNEL) on
# every cargo invocation so nothing (e.g. a future upstream rust-toolchain.toml)
# can silently hijack the channel. Already installed → rustup never hits the net.
RUST_CHANNEL="${RUST_CHANNEL:-nightly-2025-06-01}"

cd "$SRC"

# Sanitizers (§6.1): the base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting).
# rustc can't consume those clang flags, but we honor the KNOB: when $SANITIZER_FLAGS
# is non-empty we instrument the Rust build with ASan (the OSS-Fuzz Rust path); an
# explicit empty `--build-arg SANITIZER_FLAGS=` yields an un-sanitized build.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so we pin -Zdwarf-version=3
# for Rust code. The libfuzzer-sys cc shim is compiled by clang (DWARF-5 default), so we
# pin its DWARF too via CFLAGS/CXXFLAGS. $RUST_DEBUG_FLAGS threads any extra base pins.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that `-Zsanitizer=address` links is precompiled
# with clang (DWARF-5) and ships with full debug info, which would otherwise land
# DWARF-5 compile units in the final binary (its first CU) and fail the DWARF < 4
# gate. Strip the debug info from that runtime archive (a toolchain artifact, NOT
# project code). Idempotent: re-running --strip-debug on an already-stripped archive
# is a no-op, so the offline PATCH re-run stays clean.
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc +"${RUST_CHANNEL}" --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

# Upstream's own fuzz/ crate (a root-workspace member — see header note).
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (pinned nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# The root [profile.release] sets lto = true; (thin/fat) LTO fights -Zsanitizer
# instrumentation and slows the build for zero fuzzing benefit — turn it off for
# THIS build only via cargo's env override (the committed Cargo.toml is untouched).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  CARGO_PROFILE_RELEASE_LTO=false \
    cargo +"${RUST_CHANNEL}" fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # workspace-member fuzz crate → binary lands in the ROOT target dir.
  bin="$SRC/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── KAT oracle probe (mayhem/kat — standalone crate, own [workspace]) ─────────
# A small dynamically-linked binary that drives winnow's PUBLIC combinator API on
# fixed inputs and prints exact known-answer values; mayhem/test.sh greps them.
# Built CLEAN (no sanitizer, normal flags) so it is an honest oracle build.
# winnow's default feature set has NO required registry deps (memchr etc. are
# optional and off), so this resolves entirely from the path dep — no network.
echo "=== building KAT oracle probe (mayhem/kat, clean flags) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS \
  cargo +"${RUST_CHANNEL}" build --release --manifest-path mayhem/kat/Cargo.toml
KAT_BIN="$SRC/mayhem/kat/target/release/winnow-kat"
[ -x "$KAT_BIN" ] || { echo "ERROR: KAT probe not built at $KAT_BIN" >&2; exit 1; }
# Regression guard: the anti-reward-hacking oracle only works on a DYNAMICALLY
# linked binary (LD_PRELOAD must reach it) — fail the build if that regresses.
file "$KAT_BIN" | grep -q 'dynamically linked' \
  || { echo "ERROR: KAT probe is not dynamically linked — oracle would be sabotage-immune" >&2; exit 1; }
echo "built KAT probe: $KAT_BIN"

# ── Precompile the project test suite with NORMAL flags (clean, non-sanitized) ──
# so mayhem/test.sh only RUNS it. winnow's committed root Cargo.lock fully pins the
# dev-dep tree; no resolution happens here beyond reading the lock.
echo "=== building winnow test suite (cargo test --no-run) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo +"${RUST_CHANNEL}" test --no-run
echo "build.sh complete"
