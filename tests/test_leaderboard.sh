#!/bin/bash
# Trading-profit leaderboard (profit vs HODL).
#   profit = net equity − value_now(net deposited basket)
# Three traders, one price move, every property pinned:
#   • lb_win  buys 2000 ICP @ $3 from lb_lose, then ICP +20% → profit ≈ +$1,194
#     (2000 × $0.60 gain − $6 taker fee)
#   • lb_lose sold before the rise → profit ≈ −$1,203 (missed gain + maker fee)
#   • lb_hold never trades → profit EXACTLY $0 through the price move
#     (equity and HODL baseline move together — the board measures trading,
#     not market beta)
#   • setTestBalance deltas are recorded as external flows (capital = seeded $10k)
#   • a withdrawal moves equity AND baseline → profit unchanged (score can't be
#     gamed by shuffling capital)
#   • the AMM seeder's LP position is HODL-neutral too (vault untouched → ≈ 0)
# Timers paused; the snapshot is forced via adminRecomputeLeaderboard.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
SEED=$(mkid lb_seed); WIN=$(mkid lb_win); HOLD=$(mkid lb_hold); LOSE=$(mkid lb_lose)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
# my-row helper: caller's own leaderboard entry, underscores stripped.
myrow() { icp canister call --identity "$1" backend getLeaderboard '()' --query 2>&1 | tr -d '_\n' | tr -s ' ' | grep -oE "my = opt record \{[^}]*\}"; }
field() { echo "$1" | grep -oE "$2 = [-+0-9]+" | grep -oE "[-+0-9]+$"; }

# Deterministic run needs the trading bot DEAD (paused timers stop the
# heartbeat, but the sim is an external process placing real orders and
# moving the ref price mid-fixture). cold_start relaunches it later.
pkill -9 -f "simulate_trading.sh" 2>/dev/null || true
sleep 1

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" >/dev/null

# Zero every token for the test identities first — resetExchange keeps user
# balances, so a rerun would otherwise inherit its own prior fills. (Each
# zeroing SET records a flow too, so baselines stay exact.)
clean() { for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$1\", \"$t\", 0 : nat)" >/dev/null; done; }
clean "$SEED"; clean "$WIN"; clean "$HOLD"; clean "$LOSE"

# The board ranks NAMED traders — an account with no profile is the venue's own
# machinery (only controller seeding can register one without a browser), so it
# is excluded. These fixtures are funded by exactly that admin path, so they
# must identify themselves or they will not appear. Same step simulate_trading.sh
# takes for its bots.
for id in lb_seed lb_win lb_hold lb_lose; do
  icp canister call --identity "$id" backend getMyProfile "()" >/dev/null 2>&1 || true
done

# Fund everyone via setTestBalance — each SET's delta must land in the
# external-flow ledger (the HODL baseline).
adm setTestBalance "(principal \"$SEED\", \"ICP\",    $(e8 10000) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 30000) : nat)" >/dev/null
adm setTestBalance "(principal \"$WIN\",  \"ICPUSD\", $(e8 10000) : nat)" >/dev/null
adm setTestBalance "(principal \"$HOLD\", \"ICPUSD\", $(e8 10000) : nat)" >/dev/null
adm setTestBalance "(principal \"$LOSE\", \"ICP\",    $(e8 2000)  : nat)" >/dev/null
icp canister call --identity lb_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000) : nat, $(e8 30000) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
fresh() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 $1) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }
fresh 3

echo "── 1. The trade: lose sells 2000 ICP @ \$3.00, win buys them ──"
icp canister call --identity lb_lose backend placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 3) : nat, $(e8 2000) : nat)" >/dev/null 2>&1
fresh 3   # lose's ask releases and rests (inside the AMM spread)
icp canister call --identity lb_win backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 3) : nat, $(e8 2000) : nat)" >/dev/null 2>&1
fresh 3   # win's buy releases and crosses it
WIN_ICP=$(adm getTestBalance "(principal \"$WIN\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${WIN_ICP:-0}" = "$(e8 2000)" ]; then ok "trade settled: win holds 2000 ICP"; else nok "trade did not settle" "winICP=$WIN_ICP"; fi

echo ""
echo "── 2. ICP rises 20% (\$3.00 → \$3.60); snapshot the board ──"
fresh 3.6
adm adminRecomputeLeaderboard "()" >/dev/null

W=$(myrow lb_win); H=$(myrow lb_hold); L=$(myrow lb_lose); S=$(myrow lb_seed)
WP=$(field "$W" profitUsd); HP=$(field "$H" profitUsd); LP=$(field "$L" profitUsd); SP=$(field "$S" profitUsd)
WR=$(field "$W" rank); LR=$(field "$L" rank)
HC=$(field "$H" capitalUsd)
echo "   win: profit=$WP rank=$WR   hold: profit=$HP capital=$HC   lose: profit=$LP rank=$LR   seeder: profit=$SP"

# win: +$1,200 gain − $6 taker fee = +$1,194 (±$2 for rounding dust)
if awk -v p="${WP:-0}" 'BEGIN{ exit (p > 119200000000 && p < 119600000000 ? 0 : 1) }'; then
  ok "winner's profit ≈ +\$1,194 (gain − taker fee)"
else nok "winner profit off" "profitUsd=$WP (expected ≈119_400_000_000)"; fi

# hold: EXACTLY zero — the HODL-neutrality invariant.
if [ "${HP:-x}" = "0" ]; then
  ok "holder's profit is EXACTLY \$0 through the price move"
else nok "holder should score 0" "profitUsd=$HP"; fi

# hold's capital = the seeded $10k (setTestBalance delta was recorded).
if [ "${HC:-x}" = "1000000000000" ]; then
  ok "setTestBalance delta recorded as capital (\$10,000)"
else nok "capital wrong" "capitalUsd=$HC"; fi

# lose: −$1,200 missed gain − $3 maker fee ≈ −$1,203
if awk -v p="${LP:-0}" 'BEGIN{ exit (p < -120000000000 && p > -120600000000 ? 0 : 1) }'; then
  ok "seller's profit ≈ −\$1,203 (sold before the rise)"
else nok "seller profit off" "profitUsd=$LP (expected ≈ −120_300_000_000)"; fi

# seeder: LP position is HODL-neutral on marks, but the vault now earns HALF
# of every trading fee (drain fix 4), so the seeder drifts slightly POSITIVE
# with test volume — never negative.
if awk -v p="${SP:-0}" 'BEGIN{ exit (p >= 0 && p < 2500000000 ? 0 : 1) }'; then
  ok "AMM seeder ≈ flat-to-slightly-up (LP fee share) — profitUsd=$SP"
else nok "seeder should be ~flat (0 ≤ p < \$25 fee share)" "profitUsd=$SP"; fi

# Ranking: win is #1; lose is last of the ranked set.
TOT=$(icp canister call --identity anonymous backend getLeaderboard '()' --query | tr -d '_' | grep -oE "totalRanked = [0-9]+" | grep -oE "[0-9]+")
if [ "${WR:-0}" = "1" ]; then ok "winner ranked #1"; else nok "winner not #1" "rank=$WR"; fi
if [ "${LR:-0}" = "${TOT:-x}" ]; then ok "seller ranked last (#$LR of $TOT)"; else nok "seller not last" "rank=$LR of $TOT"; fi

echo ""
echo "── 3. Withdrawal neutrality: hold withdraws \$2,000 → profit still \$0 ──"
icp canister call --identity lb_hold backend withdraw '("ICPUSD", 200_000_000_000 : nat, "ext-dest")' >/dev/null 2>&1
adm adminRecomputeLeaderboard "()" >/dev/null
H2=$(myrow lb_hold)
HP2=$(field "$H2" profitUsd); HC2=$(field "$H2" capitalUsd)
echo "   hold after withdrawal: profit=$HP2 capital=$HC2"
if [ "${HP2:-x}" = "0" ]; then
  ok "withdrawal moved equity AND baseline — profit unchanged (\$0)"
else nok "withdrawal skewed the score" "profitUsd=$HP2"; fi
if [ "${HC2:-x}" = "800000000000" ]; then
  ok "capital now \$8,000 (net of the withdrawal)"
else nok "capital after withdrawal wrong" "capitalUsd=$HC2"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
