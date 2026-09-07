#!/usr/bin/env bash
#
# analyze_build_log.sh
#
# Reads a Maven build log and prints a human-readable summary:
#   - On success: a short confirmation.
#   - On failure: a categorized diagnosis (compile error, test failure,
#     dependency problem, out-of-memory, etc.) with the relevant log
#     excerpt, so you don't have to scroll through the whole console log.
#
# Usage:
#   analyze_build_log.sh <path-to-log-file> <BUILD_RESULT>
#
#   <BUILD_RESULT> is whatever Jenkins reports (SUCCESS, FAILURE, UNSTABLE, ...).
#
set -euo pipefail

LOG_FILE="${1:?usage: analyze_build_log.sh <log-file> <BUILD_RESULT>}"
BUILD_RESULT="${2:-UNKNOWN}"

if [ ! -f "$LOG_FILE" ]; then
    echo "⚠️  No build log found at '$LOG_FILE' — nothing to analyze."
    exit 0
fi

hr() { printf '%.0s-' {1..60}; printf '\n'; }

# ---------------------------------------------------------------------------
# SUCCESS PATH
# ---------------------------------------------------------------------------
if [ "$BUILD_RESULT" = "SUCCESS" ]; then
    echo "✅ Build PASSED — everything looks good!"
    hr

    TIME_LINE=$(grep -m1 -E '^\[INFO\] Total time:' "$LOG_FILE" || true)
    TESTS_LINE=$(grep -E '^Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$' "$LOG_FILE" | tail -1 || true)

    [ -n "$TIME_LINE" ] && echo "$TIME_LINE"
    [ -n "$TESTS_LINE" ] && echo "Test summary: $TESTS_LINE"

    exit 0
fi

# ---------------------------------------------------------------------------
# FAILURE PATH — try to categorize the root cause
# ---------------------------------------------------------------------------
echo "❌ Build $BUILD_RESULT — analyzing the log for the cause..."
hr

FOUND_SPECIFIC_CAUSE=0

# 1. Compilation errors
COMPILE_ERRORS=$(grep -E '\[ERROR\].*\.java:\[[0-9]+,[0-9]+\]' "$LOG_FILE" || true)
if [ -n "$COMPILE_ERRORS" ]; then
    FOUND_SPECIFIC_CAUSE=1
    echo "🔴 Category: COMPILATION ERROR"
    echo "The code does not compile. Offending line(s):"
    echo "$COMPILE_ERRORS" | head -20
    hr
fi

# 2. Test failures / errors
FAILED_TEST_SUMMARY=$(grep -E '^Tests run: [0-9]+, Failures: [1-9][0-9]*|^Tests run: [0-9]+, Failures: [0-9]+, Errors: [1-9]' "$LOG_FILE" || true)
FAILED_TEST_NAMES=$(grep -E '<<< (FAILURE|ERROR)!' "$LOG_FILE" || true)
if [ -n "$FAILED_TEST_SUMMARY" ] || [ -n "$FAILED_TEST_NAMES" ]; then
    FOUND_SPECIFIC_CAUSE=1
    echo "🔴 Category: TEST FAILURE"
    [ -n "$FAILED_TEST_NAMES" ] && { echo "Failing test(s):"; echo "$FAILED_TEST_NAMES" | head -20; }
    [ -n "$FAILED_TEST_SUMMARY" ] && { echo "Summary:"; echo "$FAILED_TEST_SUMMARY" | tail -5; }
    hr
fi

# 3. Dependency resolution problems
DEP_ERRORS=$(grep -E 'Could not resolve dependencies|Could not find artifact|Non-resolvable parent POM|Could not transfer artifact' "$LOG_FILE" || true)
if [ -n "$DEP_ERRORS" ]; then
    FOUND_SPECIFIC_CAUSE=1
    echo "🔴 Category: DEPENDENCY RESOLUTION FAILURE"
    echo "$DEP_ERRORS" | head -10
    hr
fi

# 4. Out of memory / resource exhaustion
OOM_ERRORS=$(grep -E 'OutOfMemoryError|Java heap space|GC overhead limit exceeded' "$LOG_FILE" || true)
if [ -n "$OOM_ERRORS" ]; then
    FOUND_SPECIFIC_CAUSE=1
    echo "🔴 Category: OUT OF MEMORY"
    echo "$OOM_ERRORS" | head -5
    hr
fi

# 5. Generic plugin/goal execution failure (checkstyle, spotbugs, surefire setup, etc.)
PLUGIN_ERRORS=$(grep -E '^\[ERROR\] Failed to execute goal' "$LOG_FILE" || true)
if [ -n "$PLUGIN_ERRORS" ] && [ "$FOUND_SPECIFIC_CAUSE" -eq 0 ]; then
    FOUND_SPECIFIC_CAUSE=1
    echo "🔴 Category: PLUGIN / GOAL EXECUTION FAILURE"
    echo "$PLUGIN_ERRORS" | head -10
    hr
fi

# 6. Fallback — nothing matched a known pattern, dump the most relevant tail
if [ "$FOUND_SPECIFIC_CAUSE" -eq 0 ]; then
    echo "🔴 Category: UNKNOWN — no known failure pattern matched."
    echo "Showing the last [ERROR] lines and tail of the log for manual review:"
    hr
    grep -E '^\[ERROR\]' "$LOG_FILE" | head -20 || true
    hr
    tail -40 "$LOG_FILE"
fi

echo
echo "Full log archived as a build artifact (build.log) for the complete trace."
exit 0
