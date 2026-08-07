#!/bin/bash
# UPLANDS DEX — Seed Script
# Creates dummy user accounts with substantial balances and populates
# all markets with a realistic spread of limit orders.
#
# Usage: bash scripts/seed_exchange.sh [--reset]
#   --reset  Wipe the exchange first before seeding (default: keep existing state)

export PATH="$HOME/.local/bin:$PATH"

BACKEND="tz2ag-zx777-77776-aaabq-cai"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

RESET_FIRST=false
for arg in "$@"; do
  [ "$arg" = "--reset" ] && RESET_FIRST=true
done

log()  { echo -e "${CYAN}▶${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
head() { echo -e "\n${YELLOW}═══ $1 ═══${NC}"; }

# Every call site MUST name its identity: the CLI's global default identity
# is machine-shared mutable state that other sessions and connectors move
# at will (mdex-process-safety §5) — an identity-less call would sign as
# whoever happens to be active. Refuse loudly rather than mis-seed.
call() {
  case " $* " in
    *" --identity "*) ;;
    *) echo "  ✗ call() without --identity (mdex-process-safety §5): $*" >&2; return 1 ;;
  esac
  echo "y" | icp canister call backend "$@" 2>&1
}

# ── DEPRECATED ───────────────────────────────────────────────────
# Superseded by scripts/seed.sh (the unified seed dispatcher). This script's
# order/balance literals are pre-integer-money DECIMAL amounts; the backend now
# takes Nat base units (10^8), so every call here would be rejected or mis-seed.
# Kept only for historical reference. Use:  bash scripts/seed.sh full
echo -e "${YELLOW}seed_exchange.sh is DEPRECATED${NC} — it sends pre-migration Float money." >&2
echo "Use the integer-money seeder instead:  bash scripts/seed.sh full" >&2
exit 1

# ── 0. Identities ────────────────────────────────────────────────
head "Setting up trader identities"

TRADERS=(alice bob charlie dave eve)
for name in "${TRADERS[@]}"; do
  icp identity new "$name" --storage plaintext 2>/dev/null || true
done

ALICE=$(icp identity principal --identity alice 2>/dev/null)
BOB=$(icp identity principal --identity bob 2>/dev/null)
CHARLIE=$(icp identity principal --identity charlie 2>/dev/null)
DAVE=$(icp identity principal --identity dave 2>/dev/null)
EVE=$(icp identity principal --identity eve 2>/dev/null)

echo "  alice:   $ALICE"
echo "  bob:     $BOB"
echo "  charlie: $CHARLIE"
echo "  dave:    $DAVE"
echo "  eve:     $EVE"

# ── 1. Optional reset ────────────────────────────────────────────
if $RESET_FIRST; then
  head "Resetting exchange"
  call resetExchange --identity alice
  ok "Exchange reset"
fi

# ── 2. Balances ──────────────────────────────────────────────────
head "Setting balances"

# alice — deep pockets market maker
call setTestBalance "(principal \"$ALICE\", \"ICPUSD\", 2000000.0)" --identity alice
call setTestBalance "(principal \"$ALICE\", \"BTC\",    50.0)"      --identity alice
call setTestBalance "(principal \"$ALICE\", \"ETH\",    800.0)"     --identity alice
call setTestBalance "(principal \"$ALICE\", \"ICP\",    100000.0)"  --identity alice
ok "alice: 2,000,000 ICPUSD · 50 BTC · 800 ETH · 100,000 ICP"

# bob — active swing trader
call setTestBalance "(principal \"$BOB\", \"ICPUSD\", 500000.0)" --identity bob
call setTestBalance "(principal \"$BOB\", \"BTC\",    10.0)"     --identity bob
call setTestBalance "(principal \"$BOB\", \"ETH\",    200.0)"    --identity bob
call setTestBalance "(principal \"$BOB\", \"ICP\",    20000.0)"  --identity bob
ok "bob: 500,000 ICPUSD · 10 BTC · 200 ETH · 20,000 ICP"

# charlie — medium retail trader
call setTestBalance "(principal \"$CHARLIE\", \"ICPUSD\", 100000.0)" --identity charlie
call setTestBalance "(principal \"$CHARLIE\", \"BTC\",    3.0)"      --identity charlie
call setTestBalance "(principal \"$CHARLIE\", \"ETH\",    80.0)"     --identity charlie
call setTestBalance "(principal \"$CHARLIE\", \"ICP\",    5000.0)"   --identity charlie
ok "charlie: 100,000 ICPUSD · 3 BTC · 80 ETH · 5,000 ICP"

# dave — small momentum trader
call setTestBalance "(principal \"$DAVE\", \"ICPUSD\", 50000.0)" --identity dave
call setTestBalance "(principal \"$DAVE\", \"BTC\",    1.5)"     --identity dave
call setTestBalance "(principal \"$DAVE\", \"ETH\",    40.0)"    --identity dave
call setTestBalance "(principal \"$DAVE\", \"ICP\",    2000.0)"  --identity dave
ok "dave: 50,000 ICPUSD · 1.5 BTC · 40 ETH · 2,000 ICP"

# eve — arbitrageur (lots of everything)
call setTestBalance "(principal \"$EVE\", \"ICPUSD\", 250000.0)" --identity eve
call setTestBalance "(principal \"$EVE\", \"BTC\",    8.0)"      --identity eve
call setTestBalance "(principal \"$EVE\", \"ETH\",    300.0)"    --identity eve
call setTestBalance "(principal \"$EVE\", \"ICP\",    50000.0)"  --identity eve
ok "eve: 250,000 ICPUSD · 8 BTC · 300 ETH · 50,000 ICP"

# ── 3. BTC-ICPUSD orders ─────────────────────────────────────────
# Spot ≈ 67,500.  Bids below, asks above, tight near the middle.
head "BTC-ICPUSD orders (spot ~67,500)"

log "alice — deep book both sides"
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67600.0, 0.50)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67750.0, 0.80)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 68000.0, 1.20)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 68500.0, 2.00)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 69000.0, 3.00)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 70000.0, 5.00)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67400.0, 0.60)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67200.0, 1.00)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67000.0, 1.50)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 66500.0, 2.50)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 66000.0, 4.00)' --identity alice
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 65000.0, 6.00)' --identity alice
ok "alice: 6 asks + 6 bids"

log "bob — mid-range orders"
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67650.0, 0.30)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67900.0, 0.60)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 68250.0, 0.90)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 68750.0, 1.20)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67350.0, 0.40)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67100.0, 0.70)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 66750.0, 1.00)' --identity bob
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 66200.0, 1.50)' --identity bob
ok "bob: 4 asks + 4 bids"

log "charlie — near spot orders"
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67620.0, 0.20)' --identity charlie
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67800.0, 0.35)' --identity charlie
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 68100.0, 0.50)' --identity charlie
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67380.0, 0.25)' --identity charlie
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67150.0, 0.40)' --identity charlie
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 66800.0, 0.60)' --identity charlie
ok "charlie: 3 asks + 3 bids"

log "dave — tight spread scalper"
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67530.0, 0.10)' --identity dave
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67560.0, 0.15)' --identity dave
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 67590.0, 0.20)' --identity dave
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67470.0, 0.10)' --identity dave
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67450.0, 0.15)' --identity dave
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 67420.0, 0.20)' --identity dave
ok "dave: 3 tight asks + 3 tight bids"

log "eve — wide range orders"
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 71000.0, 2.00)' --identity eve
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 73000.0, 3.00)' --identity eve
call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 75000.0, 5.00)' --identity eve
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 64000.0, 2.50)' --identity eve
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 62000.0, 4.00)' --identity eve
call placeLimitOrder '("BTC-ICPUSD", variant { buy  }, 60000.0, 6.00)' --identity eve
ok "eve: 3 wide asks + 3 wide bids"

# ── 4. ETH-ICPUSD orders ─────────────────────────────────────────
# Spot ≈ 3,450.
head "ETH-ICPUSD orders (spot ~3,450)"

log "alice"
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3470.0,  5.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3500.0,  8.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3550.0, 12.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3600.0, 20.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3700.0, 30.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3800.0, 50.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3430.0,  6.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3400.0, 10.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3350.0, 15.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3300.0, 25.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3200.0, 40.0)' --identity alice
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3000.0, 60.0)' --identity alice
ok "alice: 6 asks + 6 bids"

log "bob"
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3480.0,  3.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3520.0,  5.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3575.0,  8.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3650.0, 12.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3420.0,  4.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3380.0,  7.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3320.0, 12.0)' --identity bob
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3250.0, 18.0)' --identity bob
ok "bob: 4 asks + 4 bids"

log "charlie"
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3460.0,  2.0)' --identity charlie
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3490.0,  4.0)' --identity charlie
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3530.0,  6.0)' --identity charlie
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3440.0,  2.5)' --identity charlie
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3410.0,  4.0)' --identity charlie
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3360.0,  6.0)' --identity charlie
ok "charlie: 3 asks + 3 bids"

log "dave — tight ETH"
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3453.0, 1.0)' --identity dave
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3456.0, 1.5)' --identity dave
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3459.0, 2.0)' --identity dave
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3447.0, 1.0)' --identity dave
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3444.0, 1.5)' --identity dave
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3441.0, 2.0)' --identity dave
ok "dave: 3 tight asks + 3 tight bids"

log "eve — wide ETH"
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3900.0, 20.0)' --identity eve
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 4100.0, 30.0)' --identity eve
call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 4500.0, 50.0)' --identity eve
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 3100.0, 25.0)' --identity eve
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 2900.0, 40.0)' --identity eve
call placeLimitOrder '("ETH-ICPUSD", variant { buy  }, 2700.0, 60.0)' --identity eve
ok "eve: 3 wide asks + 3 wide bids"

# ── 5. ICP-ICPUSD orders ─────────────────────────────────────────
# Spot ≈ 12.50.
head "ICP-ICPUSD orders (spot ~12.50)"

log "alice"
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.60,  500.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.80,  800.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 13.00, 1200.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 13.50, 2000.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 14.00, 3000.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 15.00, 5000.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.40,  600.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.20, 1000.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.00, 1500.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 11.50, 2500.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 11.00, 4000.0)' --identity alice
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 10.00, 6000.0)' --identity alice
ok "alice: 6 asks + 6 bids"

log "bob"
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.65,  300.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.90,  500.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 13.25,  800.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 13.75, 1200.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.35,  400.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.10,  700.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 11.75, 1100.0)' --identity bob
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 11.25, 1700.0)' --identity bob
ok "bob: 4 asks + 4 bids"

log "charlie"
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.62,  200.0)' --identity charlie
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.85,  350.0)' --identity charlie
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 13.10,  500.0)' --identity charlie
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.38,  250.0)' --identity charlie
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.15,  400.0)' --identity charlie
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 11.90,  600.0)' --identity charlie
ok "charlie: 3 asks + 3 bids"

log "dave — tight ICP"
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.53, 100.0)' --identity dave
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.55, 150.0)' --identity dave
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 12.57, 200.0)' --identity dave
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.47, 100.0)' --identity dave
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.45, 150.0)' --identity dave
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 12.43, 200.0)' --identity dave
ok "dave: 3 tight asks + 3 tight bids"

log "eve — wide ICP"
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 16.00, 2000.0)' --identity eve
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 18.00, 3000.0)' --identity eve
call placeLimitOrder '("ICP-ICPUSD", variant { sell }, 20.00, 5000.0)' --identity eve
call placeLimitOrder '("ICP-ICPUSD", variant { buy  }, 10.00, 2500.0)' --identity eve
call placeLimitOrder '("ICP-ICPUSD", variant { buy  },  8.00, 4000.0)' --identity eve
call placeLimitOrder '("ICP-ICPUSD", variant { buy  },  6.00, 6000.0)' --identity eve
ok "eve: 3 wide asks + 3 wide bids"

# ── 6. Summary ──────────────────────────────────────────────────
head "Seeding complete"
echo ""
echo "  Markets seeded:"
echo "    BTC-ICPUSD  — 22 asks, 22 bids (~44 orders)"
echo "    ETH-ICPUSD  — 22 asks, 22 bids (~44 orders)"
echo "    ICP-ICPUSD  — 22 asks, 22 bids (~44 orders)"
echo ""
echo "  Traders: alice · bob · charlie · dave · eve"
echo ""
echo -e "  ${GREEN}Exchange seeded and ready for use!${NC}"
echo ""
