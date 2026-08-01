#!/usr/bin/env bash
# deploy_to_local.sh — deploy CODE to the local replica. Does not seed.
#
# Deploy, seed and bots are three separate verbs on purpose: a single
# "bring-up" script that did all three is how a code push became an
# accidental reseed. Seed with scripts/seed_exchange_local.sh, then start the
# fleet with scripts/start_bots_local.sh.
#
#   bash scripts/deploy_to_local.sh              # whole stack, code only
#   bash scripts/deploy_to_local.sh frontend     # frontend only (fast loop)
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_assert_posture_for_target "local"
mdx_assert_identity "local"

# Frontend-only keeps the existing fast path (rebuild + certified asset sync,
# backend and seed untouched) — the loop for verifying UI changes.
if [ "${1:-}" = "frontend" ]; then
  mdx_info "deploy → local FRONTEND only (posture #$MDX_POSTURE)"
  exec bash "$MDX_ROOT/scripts/deploy.sh" local frontend "${@:2}"
fi

# --no-seed is posture-agnostic, so a code push works on #dev and #play alike
# without the seeder's posture gate rejecting it.
mdx_info "deploy → local (env local, identity $MDX_IDENTITY, posture #$MDX_POSTURE, code only)"
exec bash "$MDX_ROOT/scripts/cold_start.sh" --no-seed "$@"
