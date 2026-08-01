#!/usr/bin/env bash
# stop_local_bots.sh — stop the LOCAL trading simulators, and nothing else.
#
# Use this instead of `pkill -f <pattern>` before running an integration test.
# Three near-identical script names live in scripts/, and a bare pattern kill
# has repeatedly taken out the LIVE subnet fleet by accident (2026-07-23,
# 2026-07-28), stopping real volume on multidex.ai for hours:
#
#   simulate_trading.sh    local simulator      ← safe to kill
#   trading_simulation.sh  local simulator      ← safe to kill (supersedes both)
#   sim_trading.sh         drives the LIVE subnet fleet — NEVER pattern-killed
#
# Why sim_trading.sh is excluded rather than filtered: the target is chosen by
# ENVIRONMENT (`IC_ENV=subnet bash scripts/sim_trading.sh …`), and environment
# assignments are NOT part of argv — `ps` shows only "bash scripts/sim_trading.sh
# 12 2" whether it is pointed at the local replica or at mainnet. No pattern can
# tell them apart, so this script never matches it at all. If you are running
# sim_trading.sh locally, stop it with the PID its own output prints.
#
# Kills by PID from pgrep (never `pkill -f`), SIGTERM first so each simulator's
# cleanup trap runs (it deletes the trader/simbot identities it created — a
# SIGKILL leaks them, and >~150 stored identities break `icp network start`).
set -uo pipefail

PATTERN='scripts/(simulate_trading|trading_simulation)\.sh'
pids=$(pgrep -f "$PATTERN" 2>/dev/null || true)

if [ -z "$pids" ]; then
  echo "stop_local_bots: no local simulators running"
  exit 0
fi

echo "stop_local_bots: stopping $(echo "$pids" | wc -l | tr -d ' ') process(es): $(echo "$pids" | tr '\n' ' ')"
for p in $pids; do kill "$p" 2>/dev/null || true; done

# Give the cleanup traps a moment, then SIGKILL only what is genuinely stuck.
sleep 2
stuck=$(pgrep -f "$PATTERN" 2>/dev/null || true)
for p in $stuck; do
  echo "stop_local_bots: $p ignored SIGTERM — SIGKILL"
  kill -9 "$p" 2>/dev/null || true
done

echo "stop_local_bots: done (live subnet fleet untouched)"
