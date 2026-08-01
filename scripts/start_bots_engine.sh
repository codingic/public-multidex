#!/usr/bin/env bash
# start_bots_engine.sh — start the trading simulator against engine, and nothing else.
#
# Thin by design: the target is in the FILENAME (so you cannot reach for the
# wrong one), in the launched process's ARGV, and in .run/bots-engine.pid.
# All logic lives in scripts/lib/bots.sh — one implementation, no drift.
#
#   MDX_BOTS=12 MDX_INTERVAL=4 bash scripts/start_bots_engine.sh
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/bots.sh"
mdx_bots_start "engine" "$@"
