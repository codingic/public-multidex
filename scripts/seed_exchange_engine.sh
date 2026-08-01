#!/usr/bin/env bash
# seed_exchange_engine.sh — seed the cloud engine (DEV DATA on a shared venue).
#
# Seeding is a first-deploy affordance: deploy.sh skips it when the exchange
# already has AMM pools, so this is safe to re-run but will usually no-op.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_assert_posture_for_target "engine"
mdx_assert_identity "engine"
mdx_info "seed → engine (identity $MDX_IDENTITY, posture #$MDX_POSTURE)"
exec env SEED=true RUN_BOTS=false bash "$MDX_ROOT/scripts/deploy.sh" cloud "$@"
