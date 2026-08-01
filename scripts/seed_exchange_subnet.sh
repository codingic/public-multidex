#!/usr/bin/env bash
# seed_exchange_subnet.sh — refuses.
#
# The subnet serves multidex.ai, where the leaderboard carries real ICP
# prizes. Seeding mints balances and lays a maker ladder; doing that on a live
# competition is exactly the operator-advantage the #play posture exists to
# make impossible (setTestBalance is recorded in extNetFlow so it cannot
# manufacture profit — but a seeded book still moves other people's fills).
#
# This script exists so that reaching for it gets a REFUSAL rather than
# finding some other script that would have gone through. If a genuine
# season-zero bring-up is needed, that is a deliberate, reviewed operation:
# scripts/deploy.sh subnet --seed, run by a human who has read the runbook.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_die "seeding the SUBNET is refused by design — it is the live venue (multidex.ai).
   Season-zero bring-up is a reviewed operation: scripts/deploy.sh subnet --seed
   See docs/deploy-to-subnet.md before you do."
