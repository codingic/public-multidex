#!/usr/bin/env bash
#
# seed_margin_book.sh — populate a realistic LEVERAGED book so the margin heat
# map (docs/margin-heatmap-design.md) and the LP risk panel show something
# meaningful. Local #play/#dev replica only.
#
# The heat map buckets positions by DISTANCE TO LIQUIDATION, and merges bands
# until each holds >= k positions (k=5 full tier). So a demo needs positions
# clustered at SEVERAL distinct leverage levels, not many at one — otherwise
# everything merges into a single wide band and the map looks broken.
#
# Liquidation distance is a pure function of leverage L (maintenance = 1.15,
# LTV = 1.0 for the majors):
#     long   P_liq/P = 1.15 × (1 − 1/L)      L=3.0 → −23%   L=4.6 → −12%
#     short  P_liq/P = (1 + 1/L) / 1.15      L=2.5 → +22%   L=4.0 →  +9%
# The initial-margin gate (health >= 1.25) caps L at 5, so the reachable span
# is roughly −25%..−8% for longs and +8%..+30% for shorts — which is why the
# tiers below stop there.
#
# Each trader opens SEVERAL pools (one position each) — a pool is a separate
# liquidation domain, so this is how a real leveraged user is structured.
#
# Usage:  bash scripts/seed_margin_book.sh [per_tier]     (default 5)
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(git rev-parse --show-toplevel)" || exit 1

PER_TIER="${1:-5}"
MKT="${MKT:-BTC-ICPUSD}"
COLL_E8=10000000000          # $100 collateral per pool — lighter, so a tier does not eat the ladder
WALLET_E8=900000000000       # $9,000 per trader wallet

GREEN='\033[0;32m'; DIM='\033[2m'; NC='\033[0m'
adm()  { echo "y" | icp canister call backend "$@" --identity anonymous 2>&1; }
usr()  { local id="$1"; shift; echo "y" | icp canister call backend "$@" --identity "$id" 2>&1; }

MARK=$(icp canister call backend getAmmPool "(\"$MKT\")" --identity anonymous --query 2>/dev/null \
       | grep -oE "refPrice = [0-9_]+" | head -1 | tr -d '_' | awk '{print $3}')
[ -z "${MARK:-}" ] || [ "$MARK" = "0" ] && { echo "no mark for $MKT — is the venue seeded?"; exit 1; }
echo -e "${DIM}market $MKT  mark=$(awk -v m="$MARK" 'BEGIN{printf "$%.2f", m/1e8}')  ${PER_TIER}/tier${NC}"

# leverage tiers → distinct liquidation bands
LONG_TIERS="3.0 3.4 3.8 4.2 4.6"
SHORT_TIERS="2.5 3.0 3.5 4.0"

# Leverage is set by the COLLATERAL, not the size.
#
# The obvious approach — fix the collateral and scale the size to hit a target
# leverage — does not work: an order only becomes a position to the extent it
# FILLS, and realized leverage follows the filled size. Against a finite AMM
# ladder the later/larger tiers fill partially (or not at all), so the intended
# leverage is not what you get. Measured on the first attempt: a 3.8x tier
# landed at −47.9% and three short tiers filled ZERO.
#
# So: use ONE small size for every position — small enough that it reliably
# fills — and vary the collateral instead. Leverage = notional / collateral, and
# collateral is exact, so the liquidation band is exact too.
POS_SIZE="${POS_SIZE:-260000}"   # ~0.0026 base ≈ $165 at $63k — fills reliably

open_one() {  # $1=identity $2=side $3=collateral_e8 $4=tag
  local ID="$1" SIDE="$2" COLL="$3" TAG="$4" POOL
  POOL=$(usr "$ID" createMarginPool "(\"$TAG\", false)" | grep -oE "ok = [0-9_]+" | tr -d '_' | awk '{print $3}')
  [ -z "${POOL:-}" ] && return 1
  usr "$ID" fundMarginPool "($POOL : nat, $COLL : nat)" >/dev/null 2>&1
  usr "$ID" openPosition "($POOL : nat, \"$MKT\", variant { $SIDE }, $POS_SIZE : nat, 5000000 : nat, null)" >/dev/null 2>&1
  return 0
}

# collateral for a target leverage, given the fixed notional
coll_for() { awk -v s="$POS_SIZE" -v m="$MARK" -v l="$1" 'BEGIN{ printf "%d", (s*m/1e8)/l }'; }

seed_tier() {  # $1=side $2=leverage $3=prefix
  local SIDE="$1" LEV="$2" PFX="$3" k ID P
  for k in $(seq 1 "$PER_TIER"); do
    ID="${ID_PFX:-mb}_${PFX}$(echo "$LEV" | tr -d '.')_$k"
    icp identity new "$ID" --storage plaintext >/dev/null 2>&1 || true
    P=$(icp identity principal --identity "$ID" 2>/dev/null)
    adm setTestEmailBinding "(principal \"$P\", \"${ID}$$@gmail.com\")" >/dev/null 2>&1
    adm setTestBalance "(principal \"$P\", \"ICPUSD\", $WALLET_E8 : nat)" >/dev/null 2>&1
    open_one "$ID" "$SIDE" "$(coll_for "$LEV")" "$ID" && N=$((N+1))
  done
  # Let the AMM requote before the next tier. Without this the ladder's depth
  # is consumed by the earlier tiers and later positions fill only a few
  # percent of their intended size — leaving them UNLEVERED, hence with no
  # liquidation price and invisible to the heat map. (That is exactly what
  # happened on the first run: tiers 4+ filled ~6% and produced no bucket.)
  sleep 4
}

# INTERLEAVE longs and shorts. Every long buys base from the vault and every
# short sells it back, so alternating keeps the AMM's inventory roughly neutral
# and its ladder quoting on both sides. Running all the longs first drains the
# vault's base and starves everything after it.
N=0
set -- $LONG_TIERS
LONGS=("$@")
set -- $SHORT_TIERS
SHORTS=("$@")
MAXT=${#LONGS[@]}; [ ${#SHORTS[@]} -gt $MAXT ] && MAXT=${#SHORTS[@]}
for ((t=0; t<MAXT; t++)); do
  if [ -n "${LONGS[$t]:-}" ]; then
    seed_tier buy "${LONGS[$t]}" l
    echo -e "  ${GREEN}✓${NC} longs  @ ${LONGS[$t]}x → liq ≈ $(awk -v l="${LONGS[$t]}" 'BEGIN{printf "%+.1f%%", (1.15*(1-1/l)-1)*100}')"
  fi
  if [ -n "${SHORTS[$t]:-}" ]; then
    seed_tier sell "${SHORTS[$t]}" s
    echo -e "  ${GREEN}✓${NC} shorts @ ${SHORTS[$t]}x → liq ≈ $(awk -v l="${SHORTS[$t]}" 'BEGIN{printf "%+.1f%%", ((1+1/l)/1.15-1)*100}')"
  fi
done

echo -e "${DIM}opened $N positions; staged orders release on the next GEPTOR pass,${NC}"
echo -e "${DIM}and the heat map recomputes on the 30s heartbeat.${NC}"

# ── Observed limits (measured, not assumed) ────────────────────────────
# Two techniques were tried; both converge on ~3 distinct bands rather than
# one per tier:
#   (a) fix collateral, scale size to the target leverage — fails because a
#       position is only as levered as it FILLS. Later/larger tiers fill
#       partially against the AMM ladder; measured a 3.8x tier landing at
#       −47.9% and three short tiers filling ZERO.
#   (b) fix a small size, vary collateral (what this script now does) — exact
#       in principle, but the release-time initial-margin CLAMP re-sizes the
#       order against the collateral actually present, so several tiers
#       collapse onto the same realized leverage.
# The result is still a legible map (longs below the mark, shorts above,
# well-separated clusters), which is what the fixture is for. Getting one
# band per tier would need the clamp bypassed — i.e. a #dev-only hook that
# writes positions directly rather than routing through the matching engine.
