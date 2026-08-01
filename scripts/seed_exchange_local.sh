#!/usr/bin/env bash
# seed_exchange_local.sh — seed the LOCAL exchange, dispatching on posture.
#
# Picking the seeder by hand fails confusingly: the #dev fixtures lean on
# setAmmRefPrice and the test overrides, which are DEAD on #play — they #err,
# and the seeder discards call output, so it "succeeds" having done nothing.
# The posture decides, not memory.
#
#   #play → cold_start --mode play : seeded AMM vault, insurance fund,
#                                    price history, maker ladder
#   #dev  → cold_start --mode full : dev fixtures (needs the #dev hooks)
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_assert_posture_for_target "local"
case "$MDX_POSTURE" in
  play) mdx_info "posture #play → cold_start.sh --mode play"
        exec bash "$MDX_ROOT/scripts/cold_start.sh" --mode play --no-simulate "$@" ;;
  dev)  mdx_info "posture #dev → cold_start.sh --mode full (dev fixtures)"
        exec bash "$MDX_ROOT/scripts/cold_start.sh" --mode full --no-simulate "$@" ;;
  *)    mdx_die "posture #$MDX_POSTURE has no local seeder" ;;
esac
