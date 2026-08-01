#!/bin/bash
# UPLANDS DEX — Cycle top-up
#
# Deposits 100T cycles (by default) onto the backend canister. Works
# on both the local pocket-ic replica and mainnet; the difference is
# only where the cycles come from:
#
#   Local   — the controller identity is auto-seeded with an
#             astronomical cycle balance at `icp network start`, so
#             `icp cycles transfer` just moves cycles within the same
#             replica. Free.
#   Mainnet — cycles have to be minted from ICP first. Set
#             MINT_ICP=true to run `icp cycles mint --cycles N` before
#             the transfer. The controller's ICP ledger account must
#             have enough ICP to cover the conversion.
#
# Usage: bash scripts/top_up_cycles.sh [OPTIONS]
#
#   --amount AMT    Cycles to deposit. Accepts suffixes k/m/b/t
#                   (thousand/million/billion/trillion). Default: 100t.
#   --canister NAME The named canister to top up (default: backend).
#                   Pass 'frontend' to top up the asset canister too.
#   --identity ID   The controller identity that pays the cycles
#                   (default: anonymous, which is the local controller).
#   --mint          On mainnet: mint cycles from ICP first. No-op locally.
#   --dry-run       Print the planned transfer but don't execute.
#
# Exit codes: 0 on success, non-zero if the transfer fails.

set -o pipefail
export PATH="$HOME/.local/bin:$PATH"

AMOUNT="100t"
CANISTER="backend"
IDENTITY="anonymous"
MINT=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --amount)    AMOUNT="$2";    shift 2 ;;
    --canister)  CANISTER="$2";  shift 2 ;;
    --identity)  IDENTITY="$2";  shift 2 ;;
    --mint)      MINT=true;      shift ;;
    --dry-run)   DRY_RUN=true;   shift ;;
    --help|-h)   sed -n '3,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

log()  { echo -e "${CYAN}▶${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1" >&2; }

# ── Resolve canister principal ───────────────────────────────────
# `icp canister status <name>` prints "Canister Id: <principal>" on
# its first line — but only when the canister is alive. A frozen /
# out-of-cycles canister returns an error message that still contains
# the principal (e.g. "Error looking up canister abc-cai: Some("IC0207")
# - Canister abc-cai is out of cycles"). We parse the happy path
# first, then fall back to the regex on the error text. This matters
# because the most common reason to run THIS script is "the canister
# ran out of cycles," and we shouldn't fail just because the diagnosis
# call requires the patient to be alive.
log "resolving principal for '$CANISTER'"
# --identity matters even for status: non-controllers get the limited view
# (no Cycles line), so the before/after balance reads come back empty.
STATUS_OUT=$(icp canister status --identity "$IDENTITY" "$CANISTER" 2>&1)
CANISTER_ID=$(echo "$STATUS_OUT" | awk -F': ' '/^Canister Id:/ {print $2; exit}')
OUT_OF_CYCLES=false
if [ -z "$CANISTER_ID" ]; then
  # Fallback: grep the error text for an IC principal-looking token.
  # Standard IC principal format is "xxxxx-...-cai" (5+ groups of
  # base32 separated by '-'). For local canisters the prefix is
  # short ("t63gs-up777-77776-aaaba-cai" etc.).
  CANISTER_ID=$(echo "$STATUS_OUT" | grep -oE "[a-z0-9]+(-[a-z0-9]+)+-cai" | head -1)
  if [ -z "$CANISTER_ID" ]; then
    err "couldn't resolve canister '$CANISTER' — replica may be down or canister truly not deployed"
    echo "    raw status output:"
    echo "$STATUS_OUT" | sed 's/^/    /'
    exit 1
  fi
  if echo "$STATUS_OUT" | grep -q "out of cycles"; then
    OUT_OF_CYCLES=true
    warn "canister is out of cycles — recovering"
  fi
fi
ok "target: $CANISTER → $CANISTER_ID"

# ── Current balance ──────────────────────────────────────────────
# Skip if the canister is frozen — `canister status` won't return a
# meaningful answer until we top it up. The post-top-up check below
# will still report the new balance.
if $OUT_OF_CYCLES; then
  BEFORE=""
  log "balance before: (unreadable — canister is frozen)"
else
  BEFORE=$(echo "$STATUS_OUT" | awk '/^  Cycles:/ {gsub(/_/, "", $2); print $2; exit}')
  log "balance before: ${BEFORE} cycles"
fi

# ── Optional mint (mainnet) ──────────────────────────────────────
if $MINT; then
  log "minting $AMOUNT cycles from ICP (identity: $IDENTITY)"
  if $DRY_RUN; then
    echo "  DRY RUN → would run: icp cycles mint --cycles $AMOUNT --identity $IDENTITY"
  else
    if ! icp cycles mint --cycles "$AMOUNT" --identity "$IDENTITY" 2>&1 | tail -5; then
      err "mint failed — does the identity have enough ICP on its ledger account?"
      exit 1
    fi
    ok "minted"
  fi
fi

# ── Top up ───────────────────────────────────────────────────────
# Must use `icp canister top-up`, NOT `icp cycles transfer`. The
# latter moves cycles between principals in the cycles ledger (wallet-
# style balance); the former calls the management canister's
# deposit_cycles which lands them on the canister's execution balance
# where they actually get burned for computation.
log "topping up $CANISTER with $AMOUNT cycles (identity: $IDENTITY)"
if $DRY_RUN; then
  echo "  DRY RUN → would run: icp canister top-up --amount $AMOUNT --identity $IDENTITY $CANISTER"
  exit 0
fi

# --identity must be forwarded here: the payment comes from the CALLER's
# cycles-ledger balance, and only the network-creator identity (anonymous
# on our local setup) carries the auto-seeded astronomical balance. Without
# the flag the ambient default identity pays — which, after a network
# recreate, holds far less than the 100T default and the transfer bounces
# with "Insufficient cycles".
if ! icp canister top-up --amount "$AMOUNT" --identity "$IDENTITY" "$CANISTER" 2>&1 | tail -5; then
  err "top-up failed"
  exit 1
fi

# ── Verify ───────────────────────────────────────────────────────
# A canister revived from out-of-cycles can take a moment to start
# accepting status calls again; one quick retry covers it.
AFTER=$(icp canister status --identity "$IDENTITY" "$CANISTER" 2>&1 | awk '/^  Cycles:/ {gsub(/_/, "", $2); print $2; exit}')
if [ -z "$AFTER" ]; then
  sleep 1
  AFTER=$(icp canister status --identity "$IDENTITY" "$CANISTER" 2>&1 | awk '/^  Cycles:/ {gsub(/_/, "", $2); print $2; exit}')
fi

# Python is the most portable way to render a big integer with thousands
# separators without depending on coreutils' locale behavior.
human() {
  python3 -c "print(f'{int(\"$1\"):,}')" 2>/dev/null || echo "$1"
}

echo ""
if [ -n "$AFTER" ]; then
  ok "balance after:  $(human "$AFTER") cycles"
  if [ -n "$BEFORE" ]; then
    DELTA=$(( AFTER - BEFORE ))
    if [ "$DELTA" -gt 0 ]; then
      ok "delta:          +$(human "$DELTA") cycles"
    fi
  fi
else
  warn "couldn't read post-top-up balance, but the top-up call succeeded"
fi
echo -e "${GREEN}Top-up complete.${NC}"
