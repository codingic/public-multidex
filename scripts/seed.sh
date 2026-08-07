#!/bin/bash
# UPLANDS DEX — Unified Seed Dispatcher
#
# One script, many seeding modes. Each mode produces a known state that
# either (a) makes UPLANDS usable for manual exploration, or (b) sets up
# a deterministic fixture that a regression test can assert against.
#
# Usage: bash scripts/seed.sh MODE [--traders N] [--history-days N]
#
# Modes:
#   full        Rich production-like state (everything on, full history).
#   empty       No-op; just verifies markets are initialized.
#   matching    2 traders, 1 market, known book. For matching-engine tests.
#   amm         1 trader, AMM seeded + enabled + oracle price set. For AMM tests.
#   pending     2 traders, 1 protected maker on the book. For pending-match tests.
#   load        N bulk-seeded principals + sparse book. For load testing.
#
# Design note:
#   Test modes (matching / amm / pending) are deliberately *minimal*. A
#   test that asserts "there are exactly 2 open orders" should not break
#   when the default seed adds a 3rd. Keep each fixture small and
#   orthogonal to the others.

set -o pipefail
export PATH="$HOME/.local/bin:$PATH"

MODE="${1:-}"
shift || true
TRADERS=100
HISTORY_DAYS=9
while [ $# -gt 0 ]; do
  case "$1" in
    --traders)      TRADERS="$2"; shift 2 ;;
    --history-days) HISTORY_DAYS="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: bash scripts/seed.sh MODE [--traders N] [--history-days N]" >&2
  echo "Modes: full | empty | matching | amm | pending | load" >&2
  exit 1
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

log()   { echo -e "${CYAN}▶${NC} $1"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1" >&2; }

# Pipe "y" into icp canister call so the interactive confirm is
# auto-accepted when candid can't be inferred.
# Every call site MUST name its identity: the CLI's global default identity
# is machine-shared mutable state that other sessions and connectors move at
# will (mdex-process-safety §5), so an identity-less call here would sign as
# whoever happens to be active. All fixtures seed as a KNOWN identity —
# refuse loudly rather than half-seed as the wrong principal.
call() {
  case " $* " in
    *" --identity "*) ;;
    *) err "call() without --identity (mdex-process-safety §5): $*"; return 1 ;;
  esac
  echo "y" | icp canister call backend "$@" 2>&1
}

# Integer-money: human decimal -> integer base units (10^8 / e8s). Money
# args (balances, prices, qtys, amounts) are now Nat base units on the wire.
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Scratch-file locations (.run/, not fixed names under sticky /tmp) — see
# scripts/lib/runfiles.sh.
# shellcheck source=scripts/lib/runfiles.sh
. "$SCRIPT_DIR/lib/runfiles.sh"

# ── Posture guard ────────────────────────────────────────────────
# Every fixture below leans on #dev-only surfaces (setAmmRefPrice, test
# overrides). On #play those #err — and because this script discards call
# output, seeding then HALF-completes in silence: pools get created,
# enabled and skew-configured while seedAmmPool's refPrice gate rejects
# the actual vault deposit, leaving an enabled-but-EMPTY AMM and no
# insurance fund (only play_start.sh seeds that). Refuse loudly instead.
# `empty` is a pure verify pass, allowed on any posture. No reachable
# backend (empty POSTURE) falls through to the modes' own errors.
if [ "$MODE" != "empty" ]; then
  POSTURE=$(icp canister call backend getDeployMode "()" --query --identity anonymous 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"')
  if [ -n "$POSTURE" ] && [ "$POSTURE" != "dev" ]; then
    err "backend posture is #$POSTURE — seed.sh fixtures are #dev-only."
    echo "     → #play bring-up (seeded AMM vault + insurance fund): bash scripts/cold_start.sh   (the default mode)" >&2
    echo "     → dev fixtures: set DEPLOY_MODE = #dev in src/backend/main.mo and redeploy first" >&2
    exit 1
  fi
fi

# ── Identity helpers ─────────────────────────────────────────────
ensure_identity() {
  local name="$1"
  icp identity new "$name" --storage plaintext 2>/dev/null || true
  icp identity principal --identity "$name" 2>/dev/null
}

# Create N "phantom" principals for load-test seeding. These aren't real
# identities (no keys generated), just deterministic Principal values
# that setTestBalance / bulkSetTestBalances accept.
# Format: self-check principals like "aaaaa-aa" won't work; we need
# well-formed text. Easiest path: derive N principals from disposable
# identities — created, read, and deleted in one pass. Only the
# principal text is used downstream (bulk admin endpoints; these users
# never sign anything), and identities must NOT linger in the global
# store: `icp network start` seeds every stored identity, and at ~150
# identities the CMC's 150,000T-cycles/hour mint cap aborts every fresh
# network start on this machine (see scripts/cleanup_identities.sh).
generate_phantom_principals() {
  local n="$1"
  local out="$2"
  > "$out"
  local i=0
  while [ "$i" -lt "$n" ]; do
    local name=$(printf "loadtrader_%04d" "$i")
    # Create identity silently; capture principal; delete immediately.
    icp identity new "$name" --storage plaintext 2>/dev/null || true
    local p=$(icp identity principal --identity "$name" 2>/dev/null)
    if [ -n "$p" ]; then echo "$p" >> "$out"; fi
    echo "y" | icp identity delete "$name" >/dev/null 2>&1 || true
    i=$(( i + 1 ))
  done
}

# ── Wait for any previous icp calls to settle ────────────────────
# Sanity-ping the backend; aborts early if the replica isn't responding.
if ! icp canister call backend getMarkets '()' --identity anonymous > /dev/null 2>&1; then
  # Maybe ensureInit hasn't run yet; try an update call to trigger it.
  alice=$(ensure_identity alice)
  if ! call resetExchange --identity alice > /dev/null 2>&1; then
    err "backend not responding; is the replica running and deployed?"
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# MODE: empty
# ═══════════════════════════════════════════════════════════════════
seed_empty() {
  log "mode=empty — clean slate (reset + market init only)"
  local alice
  alice=$(ensure_identity alice)
  # `empty` MUST reset. Tests rely on this mode to start from a known-
  # zero vault/orderbook/oracle state. A previous version of this
  # function only touched setTestBalance, leaving prior state intact —
  # which silently broke test_vault_lp's LP-anchor assertions.
  call resetExchange --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 0.0))" --identity alice > /dev/null
  ok "markets initialized · reset complete"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: matching   (minimal matching-engine fixture)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   BTC-ICPUSD book:
#     asks: [ (67600, 1.0) @ ask_alice ]
#     bids: [ (67400, 1.0) @ bid_bob   ]
#   Neither order should cross. Alice has enough BTC to sell; Bob has
#   enough ICPUSD to buy. Tests can cross them with a fresh taker.
seed_matching() {
  log "mode=matching — 2 traders, one known book on BTC-ICPUSD"
  local alice bob
  alice=$(ensure_identity alice)
  bob=$(ensure_identity bob)
  call resetExchange --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"BTC\",    $(e8 10.0))"      --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",   \"BTC\",    $(e8 10.0))"      --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",   \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 67600.0), $(e8 1.0))" --identity alice > /dev/null
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy  }, $(e8 67400.0), $(e8 1.0))" --identity bob   > /dev/null
  ok "alice: ask 1.0 BTC @ 67600 · bob: bid 1.0 BTC @ 67400"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: amm   (AMM pool + oracle, no extra traders)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   AMM pool on BTC-ICPUSD, enabled, seeded with 2 BTC + 150000 ICPUSD,
#   refPrice set to 75000 (stable, no external outcall needed). Pool
#   has NOT been requoted yet — tests that want live quotes must call
#   requoteAmm explicitly to observe deterministic placement.
seed_amm() {
  log "mode=amm — AMM pool on BTC-ICPUSD, refPrice=75000"
  local alice
  alice=$(ensure_identity alice)
  call resetExchange --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"BTC\",    $(e8 50.0))"       --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 10000000.0))" --identity alice > /dev/null
  call createAmmPool '("BTC-ICPUSD")' --identity alice > /dev/null
  call setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 75000.0))" --identity alice > /dev/null
  call seedAmmPool "(\"BTC-ICPUSD\", $(e8 2.0), $(e8 150000.0))" --identity alice > /dev/null
  call enableAmm '("BTC-ICPUSD", true)' --identity alice > /dev/null
  ok "pool seeded: 2 BTC + 150,000 ICPUSD · refPrice 75000 · enabled"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: pending   (one protected maker, ready to be crossed)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   alice has placed a protected BUY on BTC-ICPUSD at 75000.0 with a
#   10-second settlement window. bob has BTC to sell. The fixture is
#   the precondition for the pending-match regression test: bob
#   places a taker SELL at 75000, expecting a pending match (not an
#   immediate trade) to appear in getMyPendingMatches.
seed_pending() {
  log "mode=pending — alice places protected BUY, bob ready to cross"
  local alice bob
  alice=$(ensure_identity alice)
  bob=$(ensure_identity bob)
  call resetExchange --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",   \"BTC\",    $(e8 5.0))"       --identity alice > /dev/null
  call placeProtectedLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 75000.0), $(e8 1.0), 10:nat)" --identity alice > /dev/null
  ok "alice: protected BUY 1.0 BTC @ 75000 · window 10s · bob: 5 BTC loaded"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: load   (N phantom principals, sparse book, no AMM)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   $TRADERS phantom principals each have 1,000,000 ICPUSD + 10 BTC +
#   100 ETH + 5000 ICP. No open orders, no AMM. Ready for a benchmark
#   script to pound on placeLimitOrder / placeMarketOrder concurrently.
seed_load() {
  # NB: when invoked from seed_full we don't want to reset — the
  # caller has already set up a bunch of state (AMM pools, history,
  # orders). Set SKIP_RESET=true to bypass the reset.
  : "${SKIP_RESET:=false}"
  log "mode=load — generating $TRADERS trader principals"
  local alice
  alice=$(ensure_identity alice)
  if [ "$SKIP_RESET" != "true" ]; then
    call resetExchange --identity alice > /dev/null
  fi

  # Principals are derived from create-read-delete throwaway identities
  # (the bulk endpoint expects Principal values, not text). Each run
  # gets FRESH principals — fine, because load mode resets the exchange
  # and re-funds them; nothing references the previous run's principals.
  local tmpfile="$MDX_RUN_DIR/loadtrader-principals.txt"
  generate_phantom_principals "$TRADERS" "$tmpfile"
  local count
  count=$(wc -l < "$tmpfile" | tr -d ' ')
  ok "$count principals ready"

  # Build a batched bulkSetTestBalances argument. Candid vecs on the
  # CLI are verbose, so we chunk into 50 accounts per call — below the
  # argument-size limit, and each call settles in well under a second.
  log "bulk-loading balances (50 per call)"
  local batch=""
  local n=0
  local batches=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    batch+="record { principal = principal \"$p\"; balances = vec {"
    batch+="record { token = \"ICPUSD\"; amount = 100000000000000 };"
    batch+="record { token = \"BTC\";    amount = 1000000000 };"
    batch+="record { token = \"ETH\";    amount = 10000000000 };"
    batch+="record { token = \"ICP\";    amount = 500000000000 };"
    batch+="}};"
    n=$(( n + 1 ))
    if [ "$n" -ge 50 ]; then
      call bulkSetTestBalances "(vec { $batch })" --identity alice > /dev/null
      batches=$(( batches + 1 ))
      batch=""; n=0
    fi
  done < "$tmpfile"
  if [ -n "$batch" ]; then
    call bulkSetTestBalances "(vec { $batch })" --identity alice > /dev/null
    batches=$(( batches + 1 ))
  fi
  ok "balances seeded across $batches batched calls"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: full   (production-like — delegates to the legacy seed script
#               then adds AMM + oracle + historical trades)
# ═══════════════════════════════════════════════════════════════════
# ─────────────────────────────────────────────────────────────────
# Helper: seed a rich order book centred on `mid` for one market.
# Replaces the old hardcoded-price seed_exchange.sh. Prices are
# expressed as percentage offsets from mid so the distribution
# rebuilds correctly at whatever the current oracle price is.
# ─────────────────────────────────────────────────────────────────
seed_book_around() {
  local market="$1" base_token="$2" mid="$3"
  local alice bob charlie dave eve
  alice=$(ensure_identity alice); bob=$(ensure_identity bob)
  charlie=$(ensure_identity charlie); dave=$(ensure_identity dave)
  eve=$(ensure_identity eve)

  # Per-asset "small order" unit. Multipliers in the order spec below
  # scale this up — a multiplier of 20 on BTC = 0.2 BTC, on ETH = 4 ETH,
  # on ICP = 1000 ICP. Rough goal: $500-$1000 at the tight end, $5-20k at
  # the widest ends, so the book has visible structure at both scales.
  local unit
  case "$base_token" in
    BTC) unit=0.01 ;;
    ETH) unit=0.2  ;;
    SOL) unit=1.0  ;;
    ICP) unit=50   ;;
    *)   unit=1.0  ;;
  esac

  # Precompute every (identity, side, price, qty) tuple in one Python
  # call — spawning 80 subshells for individual round() calls is
  # pointlessly slow on the critical path.
  local lines
  lines=$(python3 - "$mid" "$unit" <<'PY'
import sys
mid = float(sys.argv[1]); unit = float(sys.argv[2])
# (identity, side, offset-%-from-mid, qty-multiplier).
# Structured like the original seed: 5 trader personas with distinct
# styles (tight scalper, mid-range, deep maker, wide-range).
specs = [
    # dave — tight scalper, just off the inside
    ('dave',    'sell',   0.02,  1),
    ('dave',    'sell',   0.05,  1.5),
    ('dave',    'sell',   0.08,  2),
    ('dave',    'buy',   -0.02,  1),
    ('dave',    'buy',   -0.05,  1.5),
    ('dave',    'buy',   -0.08,  2),
    # charlie — near-spot retail
    ('charlie', 'sell',   0.15,  3),
    ('charlie', 'sell',   0.35,  5),
    ('charlie', 'sell',   0.60,  8),
    ('charlie', 'buy',   -0.15,  3),
    ('charlie', 'buy',   -0.35,  5),
    ('charlie', 'buy',   -0.60,  8),
    # bob — medium swing trader
    ('bob',     'sell',   0.25,  6),
    ('bob',     'sell',   0.55,  10),
    ('bob',     'sell',   1.00,  15),
    ('bob',     'sell',   1.75,  20),
    ('bob',     'buy',   -0.25,  6),
    ('bob',     'buy',   -0.55,  10),
    ('bob',     'buy',   -1.00,  15),
    ('bob',     'buy',   -1.75,  20),
    # alice — deep maker, 6 layers each side
    ('alice',   'sell',   0.10,  10),
    ('alice',   'sell',   0.50,  20),
    ('alice',   'sell',   1.50,  30),
    ('alice',   'sell',   3.00,  40),
    ('alice',   'sell',   5.00,  50),
    ('alice',   'sell',   8.00,  80),
    ('alice',   'buy',   -0.10,  10),
    ('alice',   'buy',   -0.50,  20),
    ('alice',   'buy',   -1.50,  30),
    ('alice',   'buy',   -3.00,  40),
    ('alice',   'buy',   -5.00,  50),
    ('alice',   'buy',   -8.00,  80),
    # eve — wide-range arb
    ('eve',     'sell',   2.50,  15),
    ('eve',     'sell',   6.00,  30),
    ('eve',     'sell',  12.00,  60),
    ('eve',     'buy',   -2.50,  15),
    ('eve',     'buy',   -6.00,  30),
    ('eve',     'buy',  -12.00,  60),
]
for ident, side, off, mult in specs:
    px = round(mid * (1 + off/100), 4)
    qty = round(unit * mult, 4)
    # Tiny ICP prices can underflow to 0.00 at 4 decimals — nudge.
    if px <= 0:
        continue
    print(f"{ident}\t{side}\t{int(round(px*1e8))}\t{int(round(qty*1e8))}")
PY
  )

  local n=0
  while IFS=$'\t' read -r trader side px qty; do
    [ -z "$trader" ] && continue
    call placeLimitOrder "(\"$market\", variant { $side }, $px, $qty)" \
      --identity "$trader" > /dev/null
    n=$(( n + 1 ))
  done <<< "$lines"
  ok "$market — $n orders placed around mid $mid"
}

seed_full() {
  log "mode=full — oracle history first → book at oracle prices → AMM"

  # Step 1: reset + create named trader identities and fund them. We
  # do this BEFORE any history/book work so (a) trades exist for a
  # real Principal (used by historical injection to attribute to the
  # AMM principal — doesn't matter who alice is at that moment, but
  # ensureInit must have run so markets are in the map), and (b)
  # traders have balances ready when we place their orders.
  local alice bob charlie dave eve
  alice=$(ensure_identity alice); bob=$(ensure_identity bob)
  charlie=$(ensure_identity charlie); dave=$(ensure_identity dave)
  eve=$(ensure_identity eve)
  call resetExchange --identity alice > /dev/null
  log "funding named traders"
  # Balances generous enough that the biggest order spec (80×unit for
  # alice at mid × (1+8%)) still fits with room to spare across all
  # three markets, and traders can then act as takers during sim.
  # Alice carries the AMM seed inventory across all 3 pools — at the
  # bumped tvl_target of $500k per pool that's $1.5M ICPUSD, ~10 BTC
  # equivalent, ~200 ETH equivalent, ~200k ICP equivalent. Sized
  # generously so she still has headroom to be a normal market maker
  # after the AMM is funded.
  call setTestBalance "(principal \"$alice\",   \"ICPUSD\", $(e8 5000000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"BTC\",       $(e8 200.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"ETH\",      $(e8 5000.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"SOL\",     $(e8 50000.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"ICP\",   $(e8 1000000.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"ICPUSD\",  $(e8 500000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"BTC\",        $(e8 10.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"ETH\",       $(e8 200.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"SOL\",      $(e8 2000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"ICP\",     $(e8 20000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"ICPUSD\",  $(e8 100000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"BTC\",         $(e8 3.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"ETH\",        $(e8 80.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"SOL\",       $(e8 500.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"ICP\",      $(e8 5000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"ICPUSD\",   $(e8 50000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"BTC\",         $(e8 1.5))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"ETH\",        $(e8 40.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"SOL\",       $(e8 200.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"ICP\",      $(e8 2000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"ICPUSD\",  $(e8 250000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"BTC\",         $(e8 8.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"ETH\",       $(e8 300.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"SOL\",      $(e8 3000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"ICP\",     $(e8 50000.0))"  --identity alice > /dev/null
  ok "5 traders funded"

  # Step 2: fetch oracle prices + historical candles. Writes
  # $MDX_ORACLE_PRICES which steps 3 & 4 read.
  local oracle_file="$MDX_ORACLE_PRICES"
  rm -f "$oracle_file"
  if [ "$HISTORY_DAYS" -gt 0 ]; then
    log "injecting $HISTORY_DAYS days of oracle-derived price history"
    if ! bash "$SCRIPT_DIR/inject_history.sh" --days "$HISTORY_DAYS"; then
      warn "history injection had failures — missing assets fall back to sensible defaults"
    fi
  else
    ok "history injection skipped (--history-days 0)"
  fi

  oracle_price() {
    local asset="$1" fallback="$2"
    if [ -f "$oracle_file" ]; then
      local p
      p=$(awk -v a="$asset" '$1 == a { print $2; exit }' "$oracle_file")
      if [ -n "$p" ]; then echo "$p"; return; fi
    fi
    echo "$fallback"
  }

  local btc_px eth_px sol_px icp_px
  btc_px=$(oracle_price BTC 75000)
  eth_px=$(oracle_price ETH 3500)
  sol_px=$(oracle_price SOL 200)
  icp_px=$(oracle_price ICP 2.5)

  # Step 3: seed the order book around the current oracle prices.
  log "book seeding at oracle prices (BTC $btc_px · ETH $eth_px · SOL $sol_px · ICP $icp_px)"
  seed_book_around BTC-ICPUSD BTC "$btc_px"
  seed_book_around ETH-ICPUSD ETH "$eth_px"
  seed_book_around SOL-ICPUSD SOL "$sol_px"
  seed_book_around ICP-ICPUSD ICP "$icp_px"

  # Step 4: AMM pools — refPrice already right, pool sized for
  # robustness against simulator flow. After deploy, the price-feed
  # timer takes over refreshing refPrice every 30s via non-replicated
  # outcalls.
  #
  # tvl_target sizing: each pool needs `numLevels × quoteDepthBase`
  # of base inventory for the ask ladder AND the same value in
  # ICPUSD for the bid ladder. With 5 levels × 0.5 BTC = 2.5 BTC and
  # BTC at ~$78k that's ~$195k per side, so $500k pool gives
  # 2.5×-coverage on each side — enough headroom for the simulator
  # to flow significantly into the pool before depleting it.
  log "AMM pools"
  # Pause timers while seeding: the oracle would otherwise see the manual seed
  # refPrice as a >2.5% jump vs the live market, pend it (circuit breaker), and
  # the LP-deposit freshness gate would then block later pool seeds (it refuses
  # to mint while a HELD asset's price is frozen). Unpaused right after seeding.
  call setTestTimersPaused "(true)" --identity alice > /dev/null
  local tvl_target=500000
  for triplet in \
    "BTC-ICPUSD $btc_px" \
    "ETH-ICPUSD $eth_px" \
    "SOL-ICPUSD $sol_px" \
    "ICP-ICPUSD $icp_px"
  do
    local market price
    read -r market price <<< "$triplet"
    local base_amt quote_amt
    base_amt=$(python3 -c "print(round($tvl_target / $price / 2, 4))")
    quote_amt=$(python3 -c "print($tvl_target / 2)")
    call createAmmPool  "(\"$market\")"                       --identity alice > /dev/null
    # Inventory target + per-quote depth are NOT set here — auto-inventory
    # (enabled below) derives both from the live vault every requote: equal USD
    # per asset at 50% assets / 50% cash, with the ladder showing a fixed
    # fraction of that target per side. So every market quotes the same fraction
    # of reserves regardless of price. The $1.0 depth is just a placeholder until
    # the first requote derives the real value (decimal point required — the icp
    # CLI parses a bare "1" as Int and rejects the Float arg with no candid file).
    # spread 20bps · 15 levels · 35bps spacing → a ~5% quoted band each side.
    call setAmmConfig "(\"$market\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat, 8:nat)" --identity alice > /dev/null
    call setAmmRefPrice "(\"$market\", $(e8 $price))"               --identity alice > /dev/null
    call seedAmmPool    "(\"$market\", $(e8 $base_amt), $(e8 $quote_amt))" --identity alice > /dev/null
    # Phase 4 skew INTENSITY (200bps) — the target it leans toward is derived by
    # auto-inventory, not this seeded base amount. When holdings drift off the
    # derived target the AMM shifts its whole ladder in the opposite direction
    # (bidding less when long, asking less when short); that feedback loop, plus
    # the rebalancer, pulls the vault back toward the equal-weight allocation.
    call setAmmSkewConfig "(\"$market\", $(e8 $base_amt), 200:nat)" --identity alice > /dev/null
    call enableAmm        "(\"$market\", true)"               --identity alice > /dev/null
    ok "$market enabled · $base_amt base + $quote_amt ICPUSD · refPrice $price · skew 200bps"
  done

  # Auto-inventory: from now on each pool derives its target + quoted depth from
  # the live vault (equal USD per asset, 50/50 assets/cash). The vault was seeded
  # at that allocation above, so it starts on-target; any drift self-corrects.
  call setAmmAutoInventory "(true)" --identity alice > /dev/null
  ok "auto-inventory enabled — AMM targets equal-weight 50/50, depth derived from vault"
  # Resume timers — the oracle now refreshes the seed prices toward live market
  # (a confirmed >2.5% gap applies after two readings; cold_start waits for it).
  call setTestTimersPaused "(false)" --identity alice > /dev/null

  # Step 5: pad with load-test trader principals.
  if [ "$TRADERS" -gt 5 ]; then
    log "padding to $TRADERS trader principals"
    SKIP_RESET=true seed_load
  fi
}

# ── Dispatch ─────────────────────────────────────────────────────
case "$MODE" in
  full)     seed_full     ;;
  empty)    seed_empty    ;;
  matching) seed_matching ;;
  amm)      seed_amm      ;;
  pending)  seed_pending  ;;
  load)     seed_load     ;;
  *) err "unknown mode: $MODE"; exit 1 ;;
esac

echo ""
echo -e "${GREEN}Seed '$MODE' complete.${NC}"
