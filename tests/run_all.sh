#!/bin/bash
# tests/run_all.sh — production-friendly test runner.
#
# Discovers every test_*.sh in this directory, runs each in a fresh
# subshell, captures timing + output, and prints a structured summary.
# Returns non-zero if any test fails (CI signal).
#
# Flags:
#   --verbose            Show full per-test output instead of just
#                        the pass/fail banner. Useful when iterating.
#   --filter NAME        Only run tests whose filename matches NAME
#                        (substring match). Repeatable. Useful for
#                        running one test at a time during dev.
#   --fail-fast          Stop on first failure. Default: run all.
#   --json FILE          Emit a structured summary JSON to FILE for
#                        downstream tooling.
#   --help               Show usage.
#
# Examples:
#   bash tests/run_all.sh
#   bash tests/run_all.sh --verbose
#   bash tests/run_all.sh --filter pending --filter zombie
#   bash tests/run_all.sh --fail-fast --json /tmp/uplands-tests.json

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

VERBOSE=false
FAIL_FAST=false
JSON_OUT=""
FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose)   VERBOSE=true;  shift ;;
    --fail-fast) FAIL_FAST=true; shift ;;
    --filter)    FILTERS+=("$2"); shift 2 ;;
    --json)      JSON_OUT="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Discover tests. Sort so order is deterministic, runtime-friendly
# tests roughly first.
ALL_TESTS=( $(ls test_*.sh 2>/dev/null | sort) )
if [ ${#ALL_TESTS[@]} -eq 0 ]; then
  echo "No tests found in $SCRIPT_DIR" >&2
  exit 2
fi

# Apply filters (any filter substring match keeps the test).
if [ ${#FILTERS[@]} -gt 0 ]; then
  KEPT=()
  for t in "${ALL_TESTS[@]}"; do
    for f in "${FILTERS[@]}"; do
      if echo "$t" | grep -q -- "$f"; then KEPT+=("$t"); break; fi
    done
  done
  ALL_TESTS=( "${KEPT[@]}" )
fi

if [ ${#ALL_TESTS[@]} -eq 0 ]; then
  echo "No tests match the given filter(s): ${FILTERS[*]}" >&2
  exit 2
fi

# Stop the trading simulator if it's running. Tests assert exact trade
# counts and zero-order-book invariants; a 1Hz background simulator
# would inject noise that flakes them. The simulator is started by
# master.sh / cold_start.sh in production, not by tests.
if pgrep -f simulate_trading.sh > /dev/null 2>&1; then
  echo -e "${DIM}Stopping simulator (would interfere with assertions)…${NC}"
  pkill -f simulate_trading.sh 2>/dev/null || true
  sleep 2
fi

# ── Per-test execution ───────────────────────────────────────────
PASS=0
FAIL=0
declare -a NAMES=()
declare -a STATUSES=()
declare -a DURATIONS=()
declare -a ASSERTS_PASSED=()
declare -a ASSERTS_FAILED=()

START_ALL=$(date +%s)

# ── Motoko unit tests (mops test) ────────────────────────────────
# Pure-function tests run via moc's interpreter — no canister deploy
# needed. Sub-second total runtime; running them first means a
# regression in the math primitives surfaces before we burn 5+
# minutes on integration tests that depend on those primitives.
MOPS_PASS=0
MOPS_FAIL=0
if [ ${#FILTERS[@]} -eq 0 ] || [ "$(printf '%s\n' "${FILTERS[@]}" | grep -c -E "mops|unit")" -gt 0 ]; then
  echo -e "${BOLD}── mops test (Motoko unit tests)${NC}"
  mops_log=$(mktemp)
  start=$(date +%s)
  if mops test --reporter compact > "$mops_log" 2>&1; then
    MOPS_RC=0
  else
    MOPS_RC=1
  fi
  end=$(date +%s)
  mops_dur=$(( end - start ))
  if [ "$VERBOSE" = "true" ]; then cat "$mops_log"; fi
  if [ "$MOPS_RC" -eq 0 ]; then
    # `compact` reporter writes ANSI-control sequences; the LAST line
    # has the final tally `passed N files`. Strip ANSI before parsing.
    n_files=$(tail -3 "$mops_log" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
              | grep -oE "passed [0-9]+ files" | tail -1 \
              | grep -oE "[0-9]+" | head -1)
    echo -e "  ${GREEN}PASS${NC} (${mops_dur}s · ${n_files:-?} unit test files)"
    MOPS_PASS=1
  else
    echo -e "  ${RED}FAIL${NC} (${mops_dur}s)"
    grep -E "✖|FAIL" "$mops_log" | head -20 | sed 's/^/    /'
    MOPS_FAIL=1
    if [ "$FAIL_FAST" = "true" ]; then
      rm -f "$mops_log"
      echo ""; echo -e "${BOLD}═══ Summary ═══${NC}"
      echo -e "  ${GREEN}0 passed${NC} · ${RED}1 failed${NC} (mops unit tests)"
      exit 1
    fi
  fi
  rm -f "$mops_log"
fi

for t in "${ALL_TESTS[@]}"; do
  echo -e "${BOLD}── $t${NC}"
  log=$(mktemp /tmp/uplands-test-XXXXXX.log)
  start=$(date +%s)
  if bash "$t" > "$log" 2>&1; then
    rc=0
  else
    rc=1
  fi
  end=$(date +%s)
  dur=$(( end - start ))

  # Pass-count / fail-count parsing — tests print one ✓ or ✗ per
  # assertion. Cheap to count.
  passed=$(LC_ALL=C grep -ac '✓' "$log" || true)
  failed=$(LC_ALL=C grep -ac '✗' "$log" || true)

  if [ "$VERBOSE" = "true" ]; then
    cat "$log"
  fi

  if [ "$rc" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} (${dur}s · ${passed} assertions)"
    PASS=$(( PASS + 1 ))
    STATUSES+=("pass")
  else
    echo -e "  ${RED}FAIL${NC} (${dur}s · ${passed} ok / ${failed} failed)"
    if [ "$VERBOSE" != "true" ]; then
      # Show only the failing-assert lines + the FAIL banner so the
      # console signal is meaningful even without --verbose.
      LC_ALL=C grep -aE '✗|^FAIL' "$log" | head -20 | sed 's/^/    /'
    fi
    FAIL=$(( FAIL + 1 ))
    STATUSES+=("fail")
    if [ "$FAIL_FAST" = "true" ]; then
      NAMES+=("$t"); DURATIONS+=("$dur")
      ASSERTS_PASSED+=("$passed"); ASSERTS_FAILED+=("$failed")
      break
    fi
  fi

  rm -f "$log"
  NAMES+=("$t")
  DURATIONS+=("$dur")
  ASSERTS_PASSED+=("$passed")
  ASSERTS_FAILED+=("$failed")
done

END_ALL=$(date +%s)
TOTAL=$(( END_ALL - START_ALL ))

# ── Summary ──────────────────────────────────────────────────────
echo ""
TOTAL_PASS=$(( PASS + MOPS_PASS ))
TOTAL_FAIL=$(( FAIL + MOPS_FAIL ))
echo -e "${BOLD}═══ Summary ═══${NC}"
echo -e "  ${GREEN}$TOTAL_PASS passed${NC} · ${RED}$TOTAL_FAIL failed${NC}  (${TOTAL}s total · ${MOPS_PASS}+${PASS} unit/integration)"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo -e "${RED}Failures:${NC}"
  for i in "${!NAMES[@]}"; do
    if [ "${STATUSES[$i]}" = "fail" ]; then
      echo -e "  ${RED}✗ ${NAMES[$i]}${NC}  (${DURATIONS[$i]}s · ${ASSERTS_FAILED[$i]} failing)"
    fi
  done
fi

# Optional JSON for CI.
if [ -n "$JSON_OUT" ]; then
  {
    echo "{"
    echo "  \"summary\": { \"passed\": $PASS, \"failed\": $FAIL, \"total_seconds\": $TOTAL },"
    echo "  \"tests\": ["
    for i in "${!NAMES[@]}"; do
      sep=","
      [ "$i" -eq $(( ${#NAMES[@]} - 1 )) ] && sep=""
      echo "    { \"name\": \"${NAMES[$i]}\", \"status\": \"${STATUSES[$i]}\", \"seconds\": ${DURATIONS[$i]}, \"asserts_passed\": ${ASSERTS_PASSED[$i]}, \"asserts_failed\": ${ASSERTS_FAILED[$i]} }$sep"
    done
    echo "  ]"
    echo "}"
  } > "$JSON_OUT"
  echo -e "${DIM}  → $JSON_OUT${NC}"
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then exit 1; fi
exit 0
