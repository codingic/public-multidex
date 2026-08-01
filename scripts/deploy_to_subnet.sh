#!/usr/bin/env bash
# deploy_to_subnet.sh — deploy to subnet, and nowhere else.
#
# Thin by design: the target is in the FILENAME, so there is no flag to get
# wrong and no env var to forget. Guards (posture, identity) come from
# scripts/lib/targets.sh; the deploy itself is still scripts/deploy.sh, which
# owns the leg ordering and the anti-sybil origin re-assert.
#
#   bash scripts/deploy_to_subnet.sh              # full deploy
#   bash scripts/deploy_to_subnet.sh frontend     # frontend only
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_assert_posture_for_target "subnet"
mdx_assert_identity "subnet"
mdx_info "deploy → subnet (env $(mdx_env_for subnet), identity $MDX_IDENTITY, posture #$MDX_POSTURE)"
exec bash "$MDX_ROOT/scripts/deploy.sh" "subnet" "$@"
