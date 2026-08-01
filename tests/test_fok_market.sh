#!/bin/bash
# Fill-or-kill (noPartialFill) MARKET orders under the sealed model. A FOK market
# order now STAGES like any other, and on its first post-submission GEPTOR it
# either fully fills within the slippage cap (against fresh AMM + users) or is
# KILLED (nothing fills, reservation refunded).
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_local_bots.sh
#     bash tests/test_fok_market.sh

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money migration: trading/admin methods take Nat BASE UNITS (10^8), and
# getTestBalance now RETURNS base units. e8 converts human→base for call args;
# from_e8 converts base→human so the human-scale assertions below stay unchanged.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
# The AMM's inventory lives under its own principal — resolve it LIVE (a
# hardcoded id goes stale on every redeploy and silently zeroes the AMM's
# side of the conservation sums).
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
# bal → HUMAN units: pull the base-unit Nat (strip Candid underscores) and /1e8.
bal()  { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
# Treasury USD (human) — the maker/taker fee skims here on every fill, so the
# ICPUSD conservation set must include it (resetExchange zeroes it at setup).
treas() { local n; n=$(adm getTreasury '()' | tr -d '_' | grep -oE "balanceUsd = [0-9]+" | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
freshrequote() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }

S=$(mkid amm_seed); UA=$(mkid amm_uA)
u() { icp canister call --identity amm_uA backend "$@" 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # quiesce background timers for a deterministic run
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
# 5 levels × 100 ICP within ~1.25% → ~500 ICP of ask depth, all under a 5% cap.
# (quoteDepthBase is a base-unit Nat quantity now; spread/levels/spacing/window stay plain nats.)
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
icp canister call --identity amm_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000.0) : nat, $(e8 100000.0) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 0.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
# Closed set = {UA, AMM, seed identity, treasury}: fees skim to the treasury and
# the AMM holds the pool inventory under its own principal.
USD_BASE=$(awk -v a="$(bal "$UA" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" -v s="$(bal "$S" ICPUSD)" -v t="$(treas)" 'BEGIN{printf "%.4f", a+b+s+t}')
ICP_BASE=$(awk -v a="$(bal "$UA" ICP)" -v b="$(bal "$AMM" ICP)" -v s="$(bal "$S" ICP)" 'BEGIN{printf "%.4f", a+b+s}')

# ── 1. FOK market buy 5 ICP (within depth) stages, then FULLY fills on GEPTOR ──
echo ""
echo "── 1. FOK market buy 5 ICP → stages, then fully fills at the AMM price ──"
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
ICP_P=$(bal "$UA" ICP)
freshrequote
ICP1=$(bal "$UA" ICP)
if awk -v p="$ICP_P" 'BEGIN{exit (p<0.0000001?0:1)}' && awk -v i="$ICP1" 'BEGIN{exit (i>4.99 && i<5.01?0:1)}'; then
  ok "staged (0 ICP at placement), then FULLY filled $ICP1 ICP on release"
else nok "FOK within depth should stage then fully fill" "atPlacement=$ICP_P afterRelease=$ICP1"; fi

# ── 2. FOK market buy 2000 ICP (exceeds ~500 depth) → KILLED on GEPTOR ──
echo ""
echo "── 2. FOK market buy 2000 ICP (> available depth) → KILLED (refunded, nothing fills) ──"
ICP_B=$(bal "$UA" ICP); USD_B=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 2000.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP2=$(bal "$UA" ICP); USD2=$(bal "$UA" ICPUSD)
if awk -v a="$ICP_B" -v b="$ICP2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_B" -v b="$USD2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged ($ICP2≈$ICP_B), ICPUSD refunded ($USD2≈$USD_B)"
else nok "FOK beyond depth should kill + refund (nothing fills)" "icp $ICP_B→$ICP2, usd $USD_B→$USD2"; fi

# ── 3. Conservation ──
echo ""
echo "── 3. Conservation (UA + AMM) ──"
USD_NOW=$(awk -v a="$(bal "$UA" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" -v s="$(bal "$S" ICPUSD)" -v t="$(treas)" 'BEGIN{printf "%.4f", a+b+s+t}')
ICP_NOW=$(awk -v a="$(bal "$UA" ICP)" -v b="$(bal "$AMM" ICP)" -v s="$(bal "$S" ICP)" 'BEGIN{printf "%.4f", a+b+s}')
if awk -v a="$USD_NOW" -v b="$USD_BASE" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.02?0:1)}' \
   && awk -v a="$ICP_NOW" -v b="$ICP_BASE" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.02?0:1)}'; then
  ok "ICPUSD conserved ($USD_NOW≈$USD_BASE), ICP conserved ($ICP_NOW≈$ICP_BASE)"
else nok "value leak" "USD $USD_NOW vs $USD_BASE ; ICP $ICP_NOW vs $ICP_BASE"; fi

echo ""
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
