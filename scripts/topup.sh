#!/usr/bin/env bash
# topup.sh — keep MULTI/DEX (and its archive sidecars) fuelled on a SUBNET
# deployment, from a funded `icp` CLI wallet identity.
#
# On a dedicated subnet the exchange PAYS for its own cycles — execution, the
# 60s maintenance heartbeat, price-feed HTTPS outcalls, archive shipping, and
# (critically) spawning each ~3T archive sidecar. There is no self-funding loop
# on #play: convertTreasuryToFuel needs chain-ICP-backed treasury, and play
# treasury is fake money. So an operator tops the canister up out of a funded
# wallet. Run this on a timer (cron / systemd) — it is a one-shot check-and-fill.
#
# What it does: read the backend's cycle balance; if below LOW_WATER, top it up
# to TARGET. Optionally do the same for every archive sidecar (getArchives) and
# for the Bridge (deposit-custody) canister — the claim path runs THROUGH the
# Bridge (frontend → bridge.claim → dex.creditAndRegister), so a frozen Bridge
# breaks deposits exactly like a frozen archive breaks the Ledger tape. Unlike
# the archives, nothing in-canister reliably funds the Bridge unless the backend
# controls it, so this operator pass is its dependable fuel source.
# The whole point per the launch plan is a HUGE buffer, so the defaults are big;
# override freely.
#
#   BACKEND=<canister-id> WALLET=<identity> ./scripts/topup.sh
#   TARGET=5000 LOW_WATER=1000 ARCHIVES=true BRIDGE_TOPUP=true ARB_TOPUP=true ./scripts/topup.sh
#
# Units are TRILLIONS of cycles (T). Requires: icp CLI, a WALLET identity that
# holds cycles (or ICP the CLI can convert), and controller rights on the target.
set -uo pipefail

# ── Config (override via env) ─────────────────────────────────────────
NETWORK="${NETWORK:-ic}"                 # icp -e target: ic | local | <gateway-url>
BACKEND="${BACKEND:-backend}"            # canister id or name in icp.yaml
WALLET="${WALLET:-}"                     # REQUIRED: funded controller identity
TARGET_T="${TARGET:-5000}"              # fill up to this many T
LOW_WATER_T="${LOW_WATER:-1000}"        # …only if below this many T
ARCHIVES="${ARCHIVES:-true}"            # also top up archive sidecars?
ARCHIVE_TARGET_T="${ARCHIVE_TARGET:-50}"   # per-archive fill target (T)
ARCHIVE_LOW_T="${ARCHIVE_LOW:-15}"         # per-archive low-water (T) — must exceed the freezing reserve
BRIDGE_TOPUP="${BRIDGE_TOPUP:-true}"    # also top up the Bridge (deposit-custody) canister?
BRIDGE="${BRIDGE:-}"                     # bridge id (default: resolve from backend getBridge, else name 'bridge')
BRIDGE_TARGET_T="${BRIDGE_TARGET:-50}"     # bridge fill target (T)
BRIDGE_LOW_T="${BRIDGE_LOW:-15}"           # bridge low-water (T)
ARB_TOPUP="${ARB_TOPUP:-true}"          # also top up the arbitrageur canister?
ARB="${ARB:-}"                           # arb id (default: resolve from backend getArbitrageur, else name 'arb')
ARB_TARGET_T="${ARB_TARGET:-50}"           # arb fill target (T)
ARB_LOW_T="${ARB_LOW:-15}"                 # arb low-water (T)
DRY_RUN="${DRY_RUN:-false}"

T=1000000000000   # 1 trillion

die() { echo "topup: $*" >&2; exit 1; }
[ -n "$WALLET" ] || die "set WALLET=<funded controller identity> (see 'icp identity list')"
command -v icp >/dev/null || die "icp CLI not found"

ic() { icp "$@" -e "$NETWORK" --identity "$WALLET"; }

# Read a canister's current cycle balance (raw integer). `icp canister status`
# prints a human line like "Balance: 4_996_100_002_004 Cycles"; parse the digits
# off whichever line mentions cycles/balance. If the CLI output shape differs on
# your icp version, this is the ONE line to adjust.
cycles_of() {
  local cid="$1" out
  out="$(ic canister status "$cid" 2>/dev/null)" || return 1
  printf '%s\n' "$out" \
    | grep -iE 'balance|cycles' \
    | grep -oE '[0-9][0-9_]*' | head -1 | tr -d '_'
}

topup_to() {
  local cid="$1" target_t="$2" low_t="$3" label="$4"
  local bal; bal="$(cycles_of "$cid")"
  if [ -z "$bal" ]; then echo "  ! $label ($cid): could not read balance — skipping"; return; fi
  local bal_t=$(( bal / T ))
  if [ "$bal_t" -ge "$low_t" ]; then
    echo "  ✓ $label ($cid): ${bal_t}T ≥ ${low_t}T low-water — no top-up"
    return
  fi
  local deficit_t=$(( target_t - bal_t ))
  echo "  ↑ $label ($cid): ${bal_t}T < ${low_t}T → topping up ${deficit_t}T to ${target_t}T"
  if [ "$DRY_RUN" = "true" ]; then echo "    (dry-run: icp canister top-up --amount ${deficit_t}t $cid)"; return; fi
  if ic canister top-up --amount "${deficit_t}t" "$cid" >/dev/null 2>&1; then
    echo "    done — now ~$(( $(cycles_of "$cid") / T ))T"
  else
    echo "    ✗ top-up FAILED (wallet out of cycles? not a controller? wrong network?)" >&2
  fi
}

echo "topup: network=$NETWORK wallet=$WALLET target=${TARGET_T}T low-water=${LOW_WATER_T}T dry-run=$DRY_RUN"
topup_to "$BACKEND" "$TARGET_T" "$LOW_WATER_T" "backend"

# Archive sidecars: the DEX spawns them and is their controller, but they burn
# their own cycles (growing stable storage). getArchives lists {canisterId,…}.
if [ "$ARCHIVES" = "true" ]; then
  ids="$(ic canister call "$BACKEND" getArchives '()' --query 2>/dev/null \
         | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')"
  if [ -n "$ids" ]; then
    echo "topup: archives:"
    for a in $ids; do topup_to "$a" "$ARCHIVE_TARGET_T" "$ARCHIVE_LOW_T" "archive"; done
  else
    echo "topup: no archive sidecars reported by getArchives (none spawned yet)"
  fi
fi

# Bridge (deposit custody): a SEPARATE canister, NOT spawned by the DEX and not
# covered by any in-canister feeder unless the backend controls it — but the
# claim path depends on it. Resolve its id from the backend's wired principal
# (getBridge), falling back to the icp.yaml name 'bridge'.
if [ "$BRIDGE_TOPUP" = "true" ]; then
  bid="$BRIDGE"
  if [ -z "$bid" ]; then
    bid="$(ic canister call "$BACKEND" getBridge '()' --query 2>/dev/null \
           | grep -oE '"[a-z0-9-]+"' | tr -d '"' | head -1)"
  fi
  [ -n "$bid" ] || bid="bridge"
  echo "topup: bridge:"
  topup_to "$bid" "$BRIDGE_TARGET_T" "$BRIDGE_LOW_T" "bridge"
fi

# Arbitrageur: same shape as the Bridge — a separate self-burning canister the
# venue depends on (it pins the price to the oracle mark, ticking every ~5s).
# The backend's tickArbFuel feeds it 1T→2T from its own reservoir; this direct
# round is the fallback for when the backend itself is running thin. Resolve
# from the wired principal (getArbitrageur), falling back to the name 'arb'.
if [ "$ARB_TOPUP" = "true" ]; then
  aid="$ARB"
  if [ -z "$aid" ]; then
    aid="$(ic canister call "$BACKEND" getArbitrageur '()' --query 2>/dev/null \
           | grep -oE '"[a-z0-9-]+"' | tr -d '"' | head -1)"
  fi
  [ -n "$aid" ] || aid="arb"
  echo "topup: arb:"
  topup_to "$aid" "$ARB_TARGET_T" "$ARB_LOW_T" "arb"
fi
