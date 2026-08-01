#!/usr/bin/env bash
# bot_strategies.sh — strategy library for the MULTI/DEX trading simulation.
#
# Sourced by scripts/trading_simulation.sh; defines functions and constants
# only (no side effects at source time) so the runner owns process layout,
# funding and reporting while this file owns "what a trader actually does".
#
# WHY A LIBRARY: the old simulators gave every bot the same behaviour —
# random side, random market, random size — which produces a tape that is
# statistically flat and, more importantly, NEVER touches margin. The
# borrow engine, the liquidation batch, the 5% penalty → insurance accrual
# and the liquidation heatmap were all dead code in play mode. Here each
# bot instead runs ONE archetype with its own risk appetite, holding
# period and view, and most archetypes trade on margin.
#
# THE RISK MODEL THEY TRADE AGAINST (src/backend/lib/Types.mo):
#   health = Σ(collateral × price × LTV) / debt      LTV: ICPUSD 1.00,
#   BTC/ETH 0.90, SOL 0.85, ICP 0.80. Opening needs health ≥ 1.25
#   (INITIAL_HEALTH_RATIO); below 1.15 (MAINTENANCE) the pool is
#   liquidatable and the batch partially closes it back to 1.25, charging
#   a 5% penalty that accrues to the staked insurance fund.
#   Practical notional/collateral caps ≈ 2.8–3.6× long, 2.2–2.9× short.
#
# SIZING IS CLOSED-LOOP, NOT DERIVED. Rather than re-implement that health
# algebra in bash (easy to get subtly wrong, especially for shorts, where
# the short proceeds re-enter as collateral), a bot asks for a target
# notional and BACKS OFF on the initial-margin rejection until the backend
# accepts. The backend stays the single source of truth on risk; this file
# only has to be approximately right.
#
# LIQUIDATIONS FIRE OFF THE ORACLE, NOT THE BOOK: a bot cannot manufacture
# its own liquidation by pushing the local book around (that gate is
# deliberate — see the F1 staleness/liquidation design). Degen-archetype
# bots therefore sit close to the maintenance edge so that ORDINARY oracle
# moves of a few percent carry them through it, then re-arm afterwards.

# ── Plumbing ──────────────────────────────────────────────────────
# ENV_FLAG / REMOTE are set by the runner before sourcing (empty = local).
: "${ENV_FLAG:=}"
: "${BOT_SLIP:=0.02}"          # default max slippage on bot market orders

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
d8() { awk -v x="${1:-0}" 'BEGIN{ printf "%.8f", x/100000000 }'; }

# Update call as a bot. Never fails the caller — bots must not die on a
# transient reject; the strategy re-evaluates on its next cycle.
bcall() { local id="$1"; shift; icp canister call --identity "$id" $ENV_FLAG backend "$@" 2>&1 || true; }
# Query call. MUST carry --query: without it the CLI sends an update, which
# a cloud engine's inspect gate refuses for anonymous callers (a bug that
# once silently stopped every maker from quoting).
bquery() { local id="$1"; shift; icp canister call --query --identity "$id" $ENV_FLAG backend "$@" 2>&1 || true; }

ok_result() { echo "$1" | grep -q "ok" && ! echo "$1" | grep -q "err ="; }
err_msg()   { echo "$1" | sed -n 's/.*err = "\([^"]*\)".*/\1/p' | head -1; }

# First Nat after `field = ` in a Candid blob, as a HUMAN number.
fld8() { echo "$2" | tr -d '_' | grep -oE "$1 = [0-9]+" | grep -oE '[0-9]+' | head -1 | while read -r v; do d8 "$v"; done; }
fldi() { echo "$2" | tr -d '_' | grep -oE "$1 = [0-9]+" | grep -oE '[0-9]+' | head -1; }

base_of() { echo "${1%-ICPUSD}"; }

# Per-market "one lot" — the base-unit size a single spot order trades
# around. Chosen so a lot is roughly the same USD notional on every pair
# (~$1–2k), so the four books see comparable flow instead of BTC dominating.
bot_unit() {
  case "$1" in
    "BTC-ICPUSD") echo 0.02 ;;
    "ETH-ICPUSD") echo 0.5  ;;
    "SOL-ICPUSD") echo 20   ;;
    "ICP-ICPUSD") echo 200  ;;
    *)            echo 1    ;;
  esac
}

# Oracle mark for a market (human units). The AMM refPrice is the venue's
# fair value and the same price liquidation is judged against, so every
# strategy anchors on it rather than on last-traded (which the bots
# themselves push around).
mid() {
  icp canister call --query --identity anonymous $ENV_FLAG backend getMarkets "()" 2>&1 \
    | tr -d '\n' | tr '}' '\n' | grep "\"$1\"" \
    | grep -oE "markPrice = [0-9_.]+" | grep -oE "[0-9][0-9_.]*" | sed 's/_//g' | head -1 \
    | awk 'NF{ printf "%.8f", $1/100000000 }'
}

# ── Shared activity model ─────────────────────────────────────────
# A deterministic function of wall-clock time, so every bot speeds up and
# slows down TOGETHER with no IPC. Correlated volume is what makes a tape
# look like sessions rather than uniform noise: each 5-min bucket hashes
# to calm ×0.25 / normal ×1 / busy ×2.2 / frenzy ×5, with two slow sines
# undulating underneath. (Carried over from sim_trading.sh, which got this
# right.) Returns ~0.15–7.
activity() {
  awk -v t="$(date +%s)" 'BEGIN{
    b = int(t / 300);
    h = (b * 2654435761) % 4294967296; p = (h % 1000) / 10.0;
    if (p < 30) r = 0.25; else if (p < 70) r = 1.0; else if (p < 90) r = 2.2; else r = 5.0;
    w = 1 + 0.45 * sin(2 * 3.14159265 * t / 3600) + 0.25 * sin(2 * 3.14159265 * t / 840);
    m = r * w; if (m < 0.15) m = 0.15;
    printf "%.3f", m }'
}

# Sleep INTERVAL × jitter ÷ activity, floored so a frenzy can't busy-spin.
bot_sleep() {
  local base="${1:-$INTERVAL}" floor="${2:-0.3}"
  sleep "$(awk -v i="$base" -v r="$RANDOM" -v a="$(activity)" -v f="$floor" 'BEGIN{
    s = i * (0.5 + (r % 100) / 100.0) / a; if (s < f) s = f; printf "%.2f", s }')"
}

rand_pick() { local -a a=("$@"); echo "${a[$((RANDOM % ${#a[@]}))]}"; }

# ── Price history (the strategies' only "view") ───────────────────
# Recent closes, oldest→newest, space separated. Trend and mean-reversion
# bots read this instead of inventing a random side, which is what makes
# their flow directional and therefore capable of moving inventory (and of
# being wrong, which is what makes liquidations happen).
candle_closes() {
  local market="$1" iv="${2:-300000}" n="${3:-12}"
  # Scale inside ONE awk that emits a newline per value. Do NOT pipe through
  # d8 in a read-loop: d8 printf's without a trailing newline (it is built
  # for inline interpolation), so every close would concatenate into a single
  # token — the series would look like ONE sample, series_change_pct would
  # return 0, and trend/mean-reversion would silently never fire.
  bquery anonymous getCandles "(\"$market\", $iv : nat, 0 : nat)" \
    | tr -d '_' | grep -oE 'close = [0-9]+' | grep -oE '[0-9]+' \
    | tail -n "$n" | awk '{ printf "%.8f\n", $1/100000000 }' | tr '\n' ' '
}

# Percentage change across a close series: (last - first) / first × 100.
series_change_pct() {
  awk '{ n=NF; if (n<2 || $1+0==0) { print "0"; exit } printf "%.4f", (($n - $1) / $1) * 100 }' <<<"$1"
}
# Deviation of the last close from the series mean, in percent.
series_dev_pct() {
  awk '{ n=NF; if (n<2) { print "0"; exit } s=0; for(i=1;i<=n;i++) s+=$i; m=s/n;
         if (m==0) { print "0"; exit } printf "%.4f", (($n - m) / m) * 100 }' <<<"$1"
}

# ── Spot actions ──────────────────────────────────────────────────
spot_market_order() {
  local id="$1" market="$2" side="$3" qty="$4"
  bcall "$id" placeMarketOrder "(\"$market\", variant { $side }, $(e8 "$qty"), $(e8 "$BOT_SLIP"), false)" >/dev/null
}

spot_limit_order() {
  local id="$1" market="$2" side="$3" price="$4" qty="$5"
  bcall "$id" placeLimitOrder "(\"$market\", variant { $side }, $(e8 "$price"), $(e8 "$qty"))" >/dev/null
}

cancel_all_on() {
  local id="$1" market="$2" oid
  for oid in $(bquery "$id" getMyOrdersOnMarket "(\"$market\")" \
               | grep -oE "id = [0-9_]+" | grep -oE "[0-9_]+" | sed 's/_//g'); do
    bcall "$id" cancelMyOrder "($oid : nat)" >/dev/null
  done
}

# ── Margin helpers ────────────────────────────────────────────────
# One pool per bot, created lazily and cached in the caller's shell (each
# bot is its own process, so a plain variable is per-bot state).

# Echo the bot's pool id, creating the pool on first use. Empty on failure.
mg_ensure_pool() {
  local id="$1" name="$2" isolated="${3:-false}" existing r
  existing=$(bquery "$id" getMyMarginPools "()" | tr -d '_' | grep -oE 'id = [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -n "$existing" ]; then echo "$existing"; return; fi
  r=$(bcall "$id" createMarginPool "(\"$name\", $isolated)")
  echo "$r" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1
}

# Move ICPUSD from the bot's wallet into its pool (the collateral leg).
mg_fund() {
  local id="$1" pool="$2" amount="$3"
  bcall "$id" fundMarginPool "($pool, $(e8 "$amount") : nat)" >/dev/null
}

mg_pools_raw()     { bquery "$1" getMyMarginPools "()"; }
mg_positions_raw() { bquery "$1" getMyPositions "()"; }

# Pool equity in USD — what leverage is measured against. equityUsd is an
# Int in Candid (it can go negative on bad debt); take the magnitude and
# treat a negative as zero, since a bot with negative equity must not size
# a new position off it.
mg_equity_usd() {
  local raw; raw=$(mg_pools_raw "$1")
  echo "$raw" | tr -d '_' | grep -oE 'equityUsd = [-0-9]+' | grep -oE '[-0-9]+' | head -1 \
    | awk 'NF{ v=$1+0; if (v<0) v=0; printf "%.2f", v/100000000 }'
}

mg_is_liquidatable() { mg_pools_raw "$1" | grep -q "isLiquidatable = true"; }

# Does the bot hold an open position on this market? (size is an Int and is
# 0/absent when flat.)
mg_has_position() {
  local raw; raw=$(mg_positions_raw "$1")
  echo "$raw" | tr -d '\n' | tr '}' '\n' | grep -q "\"$2\"" || return 1
  echo "$raw" | tr -d '\n' | tr '}' '\n' | grep "\"$2\"" | grep -qE 'size = [-]?[1-9]'
}

# Signed position size on a market ("" when flat, negative = short).
mg_position_size() {
  mg_positions_raw "$1" | tr -d '_' | tr -d '\n' | tr '}' '\n' | grep "\"$2\"" \
    | grep -oE 'size = [-]?[0-9]+' | grep -oE '[-]?[0-9]+' | head -1
}

# Distance to liquidation as a PERCENT (12.5 = the mark is 12.5% away from
# this position's liquidation price). The degen archetype steers on it.
#
# UNITS: the backend reports pctToLiq as an e8 FRACTION (0.0996 = 9.96%),
# so this scales by 1e6 rather than 1e8 to hand callers a percent. Getting
# this wrong silently disables the degen archetype — it compares against a
# percent threshold, and a fraction is never greater than it.
mg_pct_to_liq() {
  mg_positions_raw "$1" | tr -d '_' | tr -d '\n' | tr '}' '\n' | grep "\"$2\"" \
    | grep -oE 'pctToLiq = opt \(?[0-9]+' | grep -oE '[0-9]+$' | head -1 \
    | awk 'NF{ printf "%.2f", $1/1000000 }'
}

mg_unrealized_pnl() {
  mg_positions_raw "$1" | tr -d '_' | tr -d '\n' | tr '}' '\n' | grep "\"$2\"" \
    | grep -oE 'unrealizedPnl = [-]?[0-9]+' | grep -oE '[-]?[0-9]+' | head -1 \
    | awk 'NF{ printf "%.2f", $1/100000000 }'
}

# OPEN a leveraged position, closed-loop on the backend's own risk gate.
# Asks for `notional_usd` of exposure and, on the initial-margin rejection,
# retries smaller (×0.6) up to MG_OPEN_TRIES times. Returns 0 if a position
# was opened. This is the single most important function here: it means the
# bots stay correct even though bash never computes a health ratio.
MG_OPEN_TRIES=${MG_OPEN_TRIES:-3}
mg_open() {
  local id="$1" pool="$2" market="$3" side="$4" notional="$5" px="$6"
  local try=0 qty r
  # Guard as a numeric test: px arrives from awk printf, so "0.00000000"
  # is a real possibility that a string compare against "0" would miss.
  awk -v p="${px:-0}" 'BEGIN{ exit !(p > 0) }' || return 1
  while [ "$try" -lt "$MG_OPEN_TRIES" ]; do
    qty=$(awk -v n="$notional" -v p="$px" 'BEGIN{ printf "%.6f", n/p }')
    # Below dust: not worth an update call.
    awk -v q="$qty" 'BEGIN{ exit !(q > 0.0000001) }' || return 1
    r=$(bcall "$id" openPosition "($pool, \"$market\", variant { $side }, $(e8 "$qty") : nat, $(e8 "$BOT_SLIP") : nat, null)")
    if ok_result "$r"; then return 0; fi
    # Anything margin/collateral shaped means "too big" — shrink and retry.
    # Other errors (stale oracle, market disabled) won't change with size.
    case "$(err_msg "$r")" in
      *[Mm]argin*|*ollateral*|*ealth*|*nsufficient*) notional=$(awk -v n="$notional" 'BEGIN{ printf "%.2f", n*0.6 }') ;;
      *) return 1 ;;
    esac
    try=$((try + 1))
  done
  return 1
}

mg_close() {
  local id="$1" pool="$2" market="$3"
  bcall "$id" closePosition "($pool, \"$market\", $(e8 "$BOT_SLIP") : nat, null)" >/dev/null
}

# Top the pool back up from the wallet if it has been drained (a liquidation
# seizes collateral, and losing bots bleed). Keeps a bot trading across the
# whole session instead of going quiet after one bad position.
mg_maintain_pool() {
  local id="$1" pool="$2" floor="$3" refill="$4" eq
  eq=$(mg_equity_usd "$id")
  [ -z "$eq" ] && eq=0
  if awk -v e="$eq" -v f="$floor" 'BEGIN{ exit !(e < f) }'; then
    mg_fund "$id" "$pool" "$refill"
    return 0
  fi
  return 1
}

# ══════════════════════════════════════════════════════════════════
# Strategies. Each runs ONE decision cycle and returns; the runner owns
# the loop and the pacing, so pacing/backoff policy lives in one place.
# ══════════════════════════════════════════════════════════════════

# MARKET MAKER (spot). Two-sided quotes a few bps off the mark,
# cancel-and-replace so the book stays bounded. This is the liquidity the
# taker archetypes and the players trade against.
strat_market_maker() {
  local id="$1" market; market=$(rand_pick "${MARKETS[@]}")
  local px; px=$(mid "$market"); [ -z "$px" ] && return
  local u; u=$(bot_unit "$market")
  cancel_all_on "$id" "$market"
  local bid ask
  bid=$(awk -v p="$px" -v r="$RANDOM" 'BEGIN{ printf "%.4f", p*(1-0.001*(1+(r%4))) }')
  ask=$(awk -v p="$px" -v r="$RANDOM" 'BEGIN{ printf "%.4f", p*(1+0.001*(1+(r%4))) }')
  spot_limit_order "$id" "$market" buy  "$bid" "$u"
  spot_limit_order "$id" "$market" sell "$ask" "$u"
}

# SCALPER (spot taker). Small, fast, direction-agnostic market orders —
# the volume floor that keeps the tape ticking between the directional
# archetypes' slower decisions. Size breathes with the activity regime.
strat_scalper() {
  local id="$1" market; market=$(rand_pick "${MARKETS[@]}")
  local u; u=$(bot_unit "$market")
  local qty; qty=$(awk -v u="$u" -v r="$RANDOM" -v a="$(activity)" 'BEGIN{
    s = sqrt(a); if (s > 2) s = 2; printf "%.6f", u * (0.3 + (r % 70) / 100.0) * s }')
  local side; side=$([ $((RANDOM % 2)) -eq 0 ] && echo buy || echo sell)
  spot_market_order "$id" "$market" "$side" "$qty"
}

# TREND FOLLOWER (margin). Reads the last hour of 5-minute candles and
# takes the side the market has been moving. Adds nothing when the tape is
# flat (below TREND_ENTRY_PCT), and flips when the trend inverts — so its
# flow is persistent and directional, which is what actually builds
# one-sided open interest in the heatmap.
TREND_ENTRY_PCT=${TREND_ENTRY_PCT:-0.35}
strat_trend() {
  local id="$1" pool="$2" lev="$3" market="$4"
  local px; px=$(mid "$market"); [ -z "$px" ] && return
  local chg; chg=$(series_change_pct "$(candle_closes "$market" 300000 12)")
  local want=""
  awk -v c="$chg" -v t="$TREND_ENTRY_PCT" 'BEGIN{ exit !(c > t) }'  && want=buy
  awk -v c="$chg" -v t="$TREND_ENTRY_PCT" 'BEGIN{ exit !(c < -t) }' && want=sell
  local size; size=$(mg_position_size "$id" "$market")
  if [ -n "$size" ] && [ "$size" != "0" ]; then
    local held; held=$([ "${size#-}" = "$size" ] && echo buy || echo sell)
    # Trend flipped against the position (or died) → step aside.
    if [ -z "$want" ] || [ "$want" != "$held" ]; then mg_close "$id" "$pool" "$market"; fi
    return
  fi
  [ -z "$want" ] && return
  local eq; eq=$(mg_equity_usd "$id"); [ -z "$eq" ] && return
  mg_open "$id" "$pool" "$market" "$want" \
    "$(awk -v e="$eq" -v l="$lev" 'BEGIN{ printf "%.2f", e*l }')" "$px"
}

# MEAN REVERTER (margin). Fades stretch: when the last close sits far from
# its own recent mean it takes the OTHER side, expecting the pull back.
# Structurally opposite to the trend bots, so the two cohorts take opposite
# sides of the book — long AND short open interest, which is what gives the
# liquidation map two populated wings instead of one.
# Calibrated against live 5-minute candles (2026-07-12): an hour of tape
# deviates from its own mean by roughly ±0.35%, so a 0.5% trigger almost
# never fired and the reverters sat out. 0.3% has them taking the other
# side of the trend cohort regularly, which is what puts SHORT interest on
# the heatmap alongside the longs.
REVERT_ENTRY_PCT=${REVERT_ENTRY_PCT:-0.3}
strat_mean_revert() {
  local id="$1" pool="$2" lev="$3" market="$4"
  local px; px=$(mid "$market"); [ -z "$px" ] && return
  local size; size=$(mg_position_size "$id" "$market")
  if [ -n "$size" ] && [ "$size" != "0" ]; then
    # Exit on reversion to fair value, or when the stretch has doubled
    # against us (the "I was early" stop).
    local dev; dev=$(series_dev_pct "$(candle_closes "$market" 300000 12)")
    local pnl; pnl=$(mg_unrealized_pnl "$id" "$market")
    local exit_now=false
    # Reverted to fair value — the thesis played out, take it off.
    if awk -v d="$dev" 'BEGIN{ exit !(d < 0.15 && d > -0.15) }'; then exit_now=true; fi
    # Or: underwater and losing patience. Explicitly separate from the
    # clause above — `A || B && C` in bash parses as `(A || B) && C`, which
    # would have gated the profitable exit behind the coin flip too.
    if awk -v p="${pnl:-0}" 'BEGIN{ exit !(p < 0) }' && [ $((RANDOM % 4)) -eq 0 ]; then exit_now=true; fi
    $exit_now && mg_close "$id" "$pool" "$market"
    return
  fi
  local dev; dev=$(series_dev_pct "$(candle_closes "$market" 300000 12)")
  local want=""
  awk -v d="$dev" -v t="$REVERT_ENTRY_PCT" 'BEGIN{ exit !(d < -t) }' && want=buy   # stretched down → buy
  awk -v d="$dev" -v t="$REVERT_ENTRY_PCT" 'BEGIN{ exit !(d > t) }'  && want=sell  # stretched up → sell
  [ -z "$want" ] && return
  local eq; eq=$(mg_equity_usd "$id"); [ -z "$eq" ] && return
  mg_open "$id" "$pool" "$market" "$want" \
    "$(awk -v e="$eq" -v l="$lev" 'BEGIN{ printf "%.2f", e*l }')" "$px"
}

# SWING TRADER (margin, low leverage). Opens with a slow bias and HOLDS,
# closing only on a large move either way. Its job in the mix is to park
# durable open interest far from the mark, so the heatmap's outer bands are
# populated rather than everything clustering at the touch.
strat_swing() {
  local id="$1" pool="$2" lev="$3" market="$4"
  local px; px=$(mid "$market"); [ -z "$px" ] && return
  local size; size=$(mg_position_size "$id" "$market")
  if [ -n "$size" ] && [ "$size" != "0" ]; then
    local pnl eq; pnl=$(mg_unrealized_pnl "$id" "$market"); eq=$(mg_equity_usd "$id")
    # Take profit at +8% of pool equity; cut at −6%. Wide, slow, patient.
    if awk -v p="${pnl:-0}" -v e="${eq:-1}" 'BEGIN{ exit !(e > 0 && (p/e > 0.08 || p/e < -0.06)) }'; then
      mg_close "$id" "$pool" "$market"
    fi
    return
  fi
  # Slow bias from a long lookback (4h of 15-minute candles).
  local chg; chg=$(series_change_pct "$(candle_closes "$market" 900000 16)")
  local want; want=$(awk -v c="$chg" 'BEGIN{ print (c >= 0) ? "buy" : "sell" }')
  local eq; eq=$(mg_equity_usd "$id"); [ -z "$eq" ] && return
  mg_open "$id" "$pool" "$market" "$want" \
    "$(awk -v e="$eq" -v l="$lev" 'BEGIN{ printf "%.2f", e*l }')" "$px"
}

# DEGEN (margin, at the edge). Runs deliberately close to the maintenance
# ratio so that an ORDINARY oracle move — the 3–5% a real crypto pair does
# in a session — carries it through liquidation. This is the archetype that
# guarantees the liquidation batch, the 5% penalty → insurance accrual and
# the hot bands of the heatmap are continuously exercised, instead of
# waiting days for a crash. After being liquidated it re-funds and re-arms,
# which is also (regrettably) realistic.
#
# It steers on pctToLiq — the backend's own distance-to-liquidation — and
# tops up exposure while that distance is still wide, rather than trying to
# compute max leverage locally.
#
# WHY 12: measured against the live gate (2026-07-12), a pool pushed until
# `openPosition` refuses lands at health ≈ 1.277 with liquidation ≈ 10%
# away — the initial-margin ratio (1.25) makes ~10% the floor a trader can
# voluntarily reach. So the target sits just above that floor: the bot adds
# until it is ~10–12% from liquidation and then stops, which an ordinary
# 10% move — a bad day in crypto, not a crash — carries it through.
DEGEN_TARGET_PCT_TO_LIQ=${DEGEN_TARGET_PCT_TO_LIQ:-12}
strat_degen() {
  local id="$1" pool="$2" lev="$3" market="$4"
  local px; px=$(mid "$market"); [ -z "$px" ] && return
  local size; size=$(mg_position_size "$id" "$market")
  if [ -n "$size" ] && [ "$size" != "0" ]; then
    local pct; pct=$(mg_pct_to_liq "$id" "$market")
    # Still comfortably far from the edge → add more risk (that is the
    # whole personality). Never closes on a loss; only takes profit.
    if [ -n "$pct" ] && awk -v p="$pct" -v t="$DEGEN_TARGET_PCT_TO_LIQ" 'BEGIN{ exit !(p > t) }'; then
      local eq held; eq=$(mg_equity_usd "$id")
      held=$([ "${size#-}" = "$size" ] && echo buy || echo sell)
      mg_open "$id" "$pool" "$market" "$held" \
        "$(awk -v e="${eq:-0}" 'BEGIN{ printf "%.2f", e*0.5 }')" "$px"
      return
    fi
    local pnl eq2; pnl=$(mg_unrealized_pnl "$id" "$market"); eq2=$(mg_equity_usd "$id")
    if awk -v p="${pnl:-0}" -v e="${eq2:-1}" 'BEGIN{ exit !(e > 0 && p/e > 0.25) }'; then
      mg_close "$id" "$pool" "$market"
    fi
    return
  fi
  # Flat: pick a side with a slight momentum lean and go straight to the edge.
  local chg; chg=$(series_change_pct "$(candle_closes "$market" 300000 6)")
  local want; want=$(awk -v c="$chg" -v r="$RANDOM" 'BEGIN{
    if (c > 0.1) print "buy"; else if (c < -0.1) print "sell";
    else print (r % 2 == 0) ? "buy" : "sell" }')
  local eq; eq=$(mg_equity_usd "$id"); [ -z "$eq" ] && return
  mg_open "$id" "$pool" "$market" "$want" \
    "$(awk -v e="$eq" -v l="$lev" 'BEGIN{ printf "%.2f", e*l }')" "$px"
}
