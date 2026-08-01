#!/usr/bin/env bash
# deploy_to_engine.sh — deploy to engine, and nowhere else.
#
# Thin by design: the target is in the FILENAME, so there is no flag to get
# wrong and no env var to forget. Guards (posture, identity) come from
# scripts/lib/targets.sh; the deploy itself is still scripts/deploy.sh, which
# owns the leg ordering and the anti-sybil origin re-assert.
#
#   bash scripts/deploy_to_engine.sh              # full deploy
#   bash scripts/deploy_to_engine.sh frontend     # frontend only
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_assert_posture_for_target "engine"
mdx_assert_identity "engine"
mdx_info "deploy → engine (env $(mdx_env_for engine), identity $MDX_IDENTITY, posture #$MDX_POSTURE)"
exec bash "$MDX_ROOT/scripts/deploy.sh" "engine" "$@"
