#!/usr/bin/env bash
#
# apache-logging-log4cxx/mayhem/test.sh — RUNS the behavioral oracle compiled by mayhem/build.sh.
#
# PATCH-grade behavioral oracle (anti-reward-hacking, SPEC §6.3):
#   Executes /mayhem/oracle-test, which exercises log4cxx's logging pipeline:
#     - BasicConfigurator + SimpleLayout → ConsoleAppender (stdout):
#         "INFO - ORACLE_TEST_MESSAGE", "WARN - ORACLE_WARN_ENTRY", "ERROR - ORACLE_ERROR_ENTRY"
#     - PatternLayout direct format (PatternParser → FormattingInfo → format):
#         "PATTERN_OK:INFO  oracle - ORACLE_PATTERN_MESSAGE"
#   test.sh GREPS the actual stdout for each expected string.  A no-op or exit(0) PATCH produces
#   NO output and fails every grep — confirming real behavior is asserted, not just exit codes.
#   (ctest counts exit(0)=PASS and is therefore INSUFFICIENT as a sole oracle here.)
#
# This script never compiles — build.sh produces /mayhem/oracle-test.  Fail loudly if missing.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

ORACLE_BIN="/mayhem/oracle-test"

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

if [ ! -x "$ORACLE_BIN" ]; then
  echo "ERROR: $ORACLE_BIN missing or not executable — run mayhem/build.sh first" >&2
  emit_ctrf "log4cxx-oracle" 0 1 0; exit 2
fi

# Run the behavioral oracle and capture its output.
echo "=== running log4cxx behavioral oracle ==="
oracle_out="$("$ORACLE_BIN" 2>&1)"; oracle_rc=$?
echo "$oracle_out"

if [ "$oracle_rc" -ne 0 ]; then
  echo "FAIL: oracle-test exited with code $oracle_rc" >&2
fi

# ── Behavioral assertions: grep the actual output for known strings.
# Each test exercises a distinct part of the log4cxx pipeline.
# A no-op/exit(0) PATCH produces no output; every grep fails → failed > 0 → test.sh exits non-zero.
PASSED=0; FAILED=0

check_output() {
  local label="$1" pattern="$2"
  if printf '%s\n' "$oracle_out" | grep -q "$pattern"; then
    echo "PASS: $label — found '$pattern'"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL: $label — expected '$pattern' in oracle output" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

# Part 1: BasicConfigurator → ConsoleAppender (default layout includes level + message).
# The default layout emits: "<ms> [<tid>] LEVEL logger ndc - message" (with possible ANSI codes).
# We grep for the level keyword and the sentinel message string together on the same line.
check_output "Logger INFO message"  "INFO.*ORACLE_TEST_MESSAGE"
check_output "Logger WARN message"  "WARN.*ORACLE_WARN_ENTRY"
check_output "Logger ERROR message" "ERROR.*ORACLE_ERROR_ENTRY"

# Part 2: PatternLayout direct format (oracle_test prefix = "PATTERN_OK:")
# Pattern "%-5p %c - %m%n" → "INFO  oracle - ORACLE_PATTERN_MESSAGE"
check_output "PatternLayout INFO"     "PATTERN_OK:INFO"
check_output "PatternLayout logger"   "PATTERN_OK:INFO  oracle - ORACLE_PATTERN_MESSAGE"

emit_ctrf "log4cxx-oracle" "$PASSED" "$FAILED" 0
