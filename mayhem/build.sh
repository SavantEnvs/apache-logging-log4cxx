#!/usr/bin/env bash
#
# apache-logging-log4cxx/mayhem/build.sh — build a focused set of log4cxx's OSS-Fuzz harnesses as
# sanitized libFuzzer targets (+ standalone reproducers), AND log4cxx's own CTest suite for
# mayhem/test.sh.
#
# Fuzzed surface (all harnesses live in src/fuzzers/cpp upstream; copies are in mayhem/harnesses/).
# We build the UTF-8 (LOG4CXX_CHAR=utf-8) encoding variant of each:
#   DOMConfiguratorFuzzer — the XML configuration parser: writes the fuzz bytes to conf.xml and calls
#                           DOMConfigurator::configure() (expat-backed XML config → appender graph).
#   PatternParserFuzzer   — the conversion-pattern parser: PatternParser::parse() over a fuzzed
#                           pattern string with the full converter rule map (%c/%d/%m/%X/...).
#   PatternLayoutFuzzer   — end-to-end: configures from PatternLayoutFuzzer.properties, then formats
#                           fuzzed log messages through a PatternLayout (the .properties config +
#                           layout formatting path).
#   TranscoderFuzzer      — the charset transcoding layer (Transcoder / CharsetDecoder /
#                           CharsetEncoder) over arbitrary bytes. This harness carries its OWN
#                           abort-on-violation round-trip oracles (UTF-8 idempotence, UTF-16BE/LE
#                           byte-encoder round trip), so it surfaces correctness defects, not just
#                           memory-safety crashes.
#
# Build contract from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). The log4cxx library ITSELF is compiled with $SANITIZER_FLAGS (CMake flag
# injection) so the fuzzed XML/pattern/transcoder code — not just the harness — is instrumented.
#
# Strategy: upstream's src/fuzzers/cpp/CMakeLists.txt already links each fuzzer against
# $ENV{LIB_FUZZING_ENGINE} (and the correct APR/apr-util/expat link line via the Find modules) when
# LIB_FUZZING_ENGINE is set. We drive that with two CMake configures sharing one source tree:
#   pass 1: LIB_FUZZING_ENGINE=-fsanitize=fuzzer    -> /mayhem/<fuzzer>            (libFuzzer)
#   pass 2: LIB_FUZZING_ENGINE=<standalone main .o> -> /mayhem/<fuzzer>-standalone (run-once repro)
# Both reuse upstream's exact link line. The CMake target name is "<Fuzzer>-<encoding>"; we install
# it at /mayhem/<Fuzzer> (encoding suffix dropped) for stable Mayhemfile target names.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: force DWARF ≤ 3 (§6.2 item 10; clang-19 defaults to DWARF-5 with plain -g).
: "${DEBUG_FLAGS:=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"

ENCODING="utf-8"
# CMake target names (upstream appends -${LOG4CXX_CHAR}); the .properties resource the
# PatternLayoutFuzzer reads next to its binary is also copied below.
FUZZERS="DOMConfiguratorFuzzer PatternParserFuzzer PatternLayoutFuzzer TranscoderFuzzer"

CXX_BUILD_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
C_BUILD_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# ── (Removed) compiled-in ASan option override ───────────────────────────────────────────────────
# NOTE: this build used to compile mayhem/asan_options.c into $ASAN_OPTIONS_OBJ and inject it into
# every link, supplying a compiled-in ASan default-options override. That is FORBIDDEN — verify-repo.sh
# hard-fails any such override under mayhem/, because Mayhem alone owns the ASan/LibFuzzer option set.
# On vorbis and muparser, real dispatched runs came back healthy (edges UP, not zero) once the
# equivalent override was removed.
ASAN_OPTIONS_OBJ=""

# Base CMake flags shared by both passes (compiler selection, build type, targets).
# C/CXX flags are NOT included here so each pass can set its own sanitizer mix.
CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
  -DBUILD_EXAMPLES=OFF
  -DBUILD_FUZZERS=ON
  -DLOG4CXX_CHAR="$ENCODING"
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
)

cmake_targets() { for f in $FUZZERS; do echo "$f-$ENCODING"; done; }

# ── pass 1: libFuzzer targets ────────────────────────────────────────────────────────────────────
# Add -fsanitize=fuzzer-no-link so the log4cxx library AND each harness TU gets libFuzzer's
# SanitizerCoverage edge instrumentation.  Without it the library is compiled with ASan/UBSan
# only → no coverage feedback → 0 edges on every run.  The fuzzer runtime itself comes from
# LIB_FUZZING_ENGINE=-fsanitize=fuzzer (linked by upstream's CMakeLists.txt).
export LIB_FUZZING_ENGINE="-fsanitize=fuzzer"
BUILD_FUZZ="$SRC/mayhem-build-fuzz"
rm -rf "$BUILD_FUZZ"; mkdir -p "$BUILD_FUZZ"

# ---------------------------------------------------------------------------
# Stage our corrected harness copies over upstream's, at BUILD TIME.
#
# DOMConfiguratorFuzzer needs a read-only-scratch fix: upstream writes the fuzz bytes to a
# CWD-relative "conf.xml", but Mayhem mounts the image read-only during coverage collection, so that
# fopen() returns NULL, the harness returns early, and the target records 0 edges. Our copy in
# mayhem/harnesses/ writes to /dev/shm instead (a kernel tmpfs Docker keeps writable even under
# --read-only). SPEC §6.2 item 13.
#
# That fix used to be applied by EDITING src/fuzzers/cpp/DOMConfiguratorFuzzer.cpp in place, which
# broke the additive invariant — verify-repo.sh flagged "non-additive changes vs upstream (breaks
# clean replay): M src/fuzzers/cpp/DOMConfiguratorFuzzer.cpp". The upstream file is now untouched in
# git and the corrected copy is staged in here instead, so the layer stays all-A. (The copies under
# mayhem/harnesses/ already existed but were dead — nothing referenced them.)
for h in $FUZZERS; do
  if [ -f "$SRC/mayhem/harnesses/$h.cpp" ]; then
    cp -f "$SRC/src/fuzzers/cpp/$h.cpp" "$SRC/mayhem-build-$h.cpp.upstream"
    cp -f "$SRC/mayhem/harnesses/$h.cpp" "$SRC/src/fuzzers/cpp/$h.cpp"
    echo "staged mayhem/harnesses/$h.cpp -> src/fuzzers/cpp/$h.cpp"
  fi
done
# Restore upstream's originals on exit so the tree is left as committed (idempotent re-runs, and the
# standalone/oracle builds below see pristine sources).
restore_harnesses() {
  for h in $FUZZERS; do
    [ -f "$SRC/mayhem-build-$h.cpp.upstream" ] \
      && mv -f "$SRC/mayhem-build-$h.cpp.upstream" "$SRC/src/fuzzers/cpp/$h.cpp"
  done
}
trap restore_harnesses EXIT
( cd "$BUILD_FUZZ" && cmake "$SRC" "${CMAKE_COMMON[@]}" \
    -DCMAKE_C_FLAGS="$C_BUILD_FLAGS -fsanitize=fuzzer-no-link" \
    -DCMAKE_CXX_FLAGS="$CXX_BUILD_FLAGS -fsanitize=fuzzer-no-link" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $ASAN_OPTIONS_OBJ" )
make -C "$BUILD_FUZZ" -j"$MAYHEM_JOBS" $(cmake_targets)
for f in $FUZZERS; do
  src_bin="$(find "$BUILD_FUZZ/src/fuzzers/cpp" -maxdepth 1 -type f -name "$f-$ENCODING" | head -1)"
  cp "$src_bin" "/mayhem/$f"
  echo "built libFuzzer target /mayhem/$f"
done

# ── pass 2: standalone reproducers ───────────────────────────────────────────────────────────────
# Compile the run-once standalone main (C) as an object, then re-link the SAME harnesses against it
# by pointing LIB_FUZZING_ENGINE at the object instead of libFuzzer.
SA_OBJ="$SRC/mayhem-standalone-main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA_OBJ"
export LIB_FUZZING_ENGINE="$SA_OBJ"
BUILD_SA="$SRC/mayhem-build-standalone"
rm -rf "$BUILD_SA"; mkdir -p "$BUILD_SA"
( cd "$BUILD_SA" && cmake "$SRC" "${CMAKE_COMMON[@]}" \
    -DCMAKE_C_FLAGS="$C_BUILD_FLAGS" \
    -DCMAKE_CXX_FLAGS="$CXX_BUILD_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $ASAN_OPTIONS_OBJ" )
make -C "$BUILD_SA" -j"$MAYHEM_JOBS" $(cmake_targets)
for f in $FUZZERS; do
  src_bin="$(find "$BUILD_SA/src/fuzzers/cpp" -maxdepth 1 -type f -name "$f-$ENCODING" | head -1)"
  cp "$src_bin" "/mayhem/$f-standalone"
  echo "built standalone reproducer /mayhem/$f-standalone"
done

# PatternLayoutFuzzer reads PatternLayoutFuzzer.properties from its own directory (chdir to exe home).
cp "$SRC/mayhem/resources/PatternLayoutFuzzer.properties" /mayhem/PatternLayoutFuzzer.properties

# ── test suite: build log4cxx's OWN CTest suite with NORMAL flags (no sanitizers) so test.sh is an
#    honest PATCH oracle and only RUNS the pre-built suite. Separate tree. ─────────────────────────
BUILD_TESTS="$SRC/mayhem-tests"
rm -rf "$BUILD_TESTS"; mkdir -p "$BUILD_TESTS"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$BUILD_TESTS" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_FUZZERS=OFF \
    -DLOG4CXX_CHAR="$ENCODING" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$BUILD_TESTS" -j"$MAYHEM_JOBS"
echo "built log4cxx CTest suite in mayhem-tests/"

# ── oracle_test: behavioral test binary for mayhem/test.sh (compiled against the test-suite build)
# Greps for known output strings; a no-op/exit(0) patch produces no output and fails the grep.
LOG4CXX_LIB="$BUILD_TESTS/src/main/cpp/liblog4cxx.a"
LOG4CXX_INCLUDE_SRC="$SRC/src/main/include"
LOG4CXX_INCLUDE_BUILD="$BUILD_TESTS/src/main/include"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  "$CXX" -std=c++17 \
    -I"$LOG4CXX_INCLUDE_SRC" -I"$LOG4CXX_INCLUDE_BUILD" \
    "$SRC/mayhem/harnesses/oracle_test.cpp" \
    "$LOG4CXX_LIB" \
    -laprutil-1 -lapr-1 -lexpat -lpthread \
    -o /mayhem/oracle-test
echo "built behavioral oracle /mayhem/oracle-test"

echo "build.sh complete:"
ls -la /mayhem/DOMConfiguratorFuzzer /mayhem/PatternParserFuzzer \
       /mayhem/PatternLayoutFuzzer /mayhem/TranscoderFuzzer \
       /mayhem/DOMConfiguratorFuzzer-standalone /mayhem/PatternParserFuzzer-standalone \
       /mayhem/PatternLayoutFuzzer-standalone /mayhem/TranscoderFuzzer-standalone 2>&1 || true
