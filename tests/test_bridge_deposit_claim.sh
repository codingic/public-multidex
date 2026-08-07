#!/bin/bash
# tests/test_bridge_deposit_claim.sh
#
# End-to-end regression for the (stub) Bridge canister ↔ DEX deposit→claim path
# (src/bridge/main.mo + backend creditAndRegister). Covers:
#   • createDepositAddress reveals the per-chain addresses
#   • two-ledger CREDIT axis: devSimulateDeposit→pending, devConfirmDeposits→
#     confirmed; claimable = confirmed − claimed
#   • claim() credits the DEX virtual wallet (via the inter-canister
#     creditAndRegister, which also REGISTERS the user) and advances the
#     `claimed` high-water mark
#   • idempotency: a second claim with nothing new is a no-op (balance unchanged)
#   • a later confirm+claim credits ONLY the delta
#   • creditAndRegister gating: a rogue (non-bridge, non-controller) caller is
#     rejected and gets no credit; amount 0 is rejected
#
# NON-DESTRUCTIVE: scoped to a throwaway identity and never calls resetExchange,
# so it is safe to run against a live/seeded exchange. Uses _lib.sh assertions but
# its own summary (the global vault/book invariants are irrelevant to this path).

source "$(dirname "$0")/_lib.sh"

BRIDGE_ID=$(icp canister status bridge  --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -z "$BRIDGE_ID" ] || [ -z "$BACKEND_ID" ]; then
  echo "bridge/backend canister not found — deploy them first (icp deploy)"; exit 1
fi

# bridge-canister call wrapper (the _lib.sh `call` targets the backend).
bcall() { echo "y" | icp canister call bridge "$@" 2>&1; }
newid() { icp identity delete "$1" --yes >/dev/null 2>&1 || echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true
          icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
delid() { icp identity delete "$1" --yes >/dev/null 2>&1 || echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true; }

echo "── test_bridge_deposit_claim ──"

# (0) wire bridge ↔ DEX (idempotent; controller = anonymous locally)
call  setBridge "(principal \"$BRIDGE_ID\")"  --identity anonymous >/dev/null
bcall setDex    "(principal \"$BACKEND_ID\")" --identity anonymous >/dev/null

# throwaway user (deleted first → fresh principal → clean bridge ledger each run)
U="brdgtest"; ROGUE="brdgrogue"
newid "$U"; newid "$ROGUE"
UPRIN=$(principal_of "$U"); RPRIN=$(principal_of "$ROGUE")

# Bind U to a throwaway verified email (unique per run — bindings are
# first-come and survive reruns): on #play the deposit allowance gate refuses
# unbound principals at admission; on #dev (no cap) the binding is inert.
call setTestEmailBinding "(principal \"$UPRIN\", \"brdgtest${RANDOM}$$@gmail.com\")" --identity anonymous >/dev/null

# The play deposit cap is active on EVERY non-production posture (posture
# doctrine, main.mo DEPLOY_MODE) and values a BTC deposit at the venue mark
# AT SIMULATE TIME. In a full-suite run an earlier resetExchange can leave
# this venue with no BTC mark, which refuses the simulate outright ("no mark
# price") and cascades through every claim below. Provision a mark via the
# dev hook; a #play venue always carries live marks (GEPTOR requotes), and
# the hook is dead there anyway.
MODE=$(call getDeployMode '()' --query 2>/dev/null | grep -oE 'dev|play|production' | head -1)
if [ "$MODE" = "dev" ]; then
  call createAmmPool '("BTC-ICPUSD")' --identity anonymous >/dev/null 2>&1 || true
  call setAmmRefPrice '("BTC-ICPUSD", 5000000000000 : nat)' --identity anonymous >/dev/null   # $50k valuation mark
fi

# (1) addresses revealed, in native formats
ADDRS=$(bcall createDepositAddress '()' --identity "$U")
assert_contains "createDepositAddress lists BTC" "$ADDRS" "BTC"
assert_contains "BTC address is bech32 (bc1q…)"  "$ADDRS" "bc1q"

# (2) simulate a 0.5 BTC deposit → pending only
bcall devSimulateDeposit '("BTC", 50000000 : nat)' --identity "$U" >/dev/null
DEP=$(bcall getMyDeposits '()' --identity "$U")     # BTC is the first record
assert_eq "BTC pending after simulate" "50000000" "$(extract_nat pending "$DEP")"
assert_eq "BTC confirmed still 0"      "0"        "$(extract_nat confirmed "$DEP")"
assert_eq "BTC claimable still 0"      "0"        "$(extract_nat claimable "$DEP")"

# (3) confirm → confirmed; claimable = confirmed − claimed
bcall devConfirmDeposits '()' --identity "$U" >/dev/null
DEP=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "BTC confirmed after confirm" "50000000" "$(extract_nat confirmed "$DEP")"
assert_eq "BTC pending back to 0"       "0"        "$(extract_nat pending "$DEP")"
assert_eq "BTC claimable = confirmed"   "50000000" "$(extract_nat claimable "$DEP")"

# (4) claim → #ok; DEX wallet credited + user registered (credit proves the path ran)
# getTestBalance is scoped to self-or-controller, and $UPRIN/$RPRIN are
# throwaway identities that are NOT us — so read them as the controller
# (anonymous, locally); the bare ambient identity would read silent zeros.
CLAIM=$(bcall claim '("BTC")' --identity "$U")
assert_contains "claim BTC returns ok = 50000000" "$CLAIM" "ok = 50000000"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")" --identity anonymous)
assert_eq "DEX BTC balance credited" "50000000" "$(extract_first_nat "$BAL")"

# (5) claimed high-water advanced, claimable back to 0
DEP=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "BTC claimed = 50000000" "50000000" "$(extract_nat claimed "$DEP")"
assert_eq "BTC claimable now 0"    "0"        "$(extract_nat claimable "$DEP")"

# (6) idempotent re-claim: rejected, balance unchanged (no double-credit)
CLAIM2=$(bcall claim '("BTC")' --identity "$U")
assert_contains "re-claim rejected (nothing to claim)" "$CLAIM2" "Nothing to claim"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")" --identity anonymous)
assert_eq "DEX BTC balance unchanged after re-claim" "50000000" "$(extract_first_nat "$BAL")"

# (7) a later confirm+claim credits ONLY the new delta (0.25 BTC)
bcall devSimulateDeposit '("BTC", 25000000 : nat)' --identity "$U" >/dev/null
bcall devConfirmDeposits '()' --identity "$U" >/dev/null
CLAIM3=$(bcall claim '("BTC")' --identity "$U")
assert_contains "second claim ok = 25000000 (delta only)" "$CLAIM3" "ok = 25000000"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")" --identity anonymous)
assert_eq "DEX BTC balance = 0.75 cumulative" "75000000" "$(extract_first_nat "$BAL")"

# (8) creditAndRegister gating: a rogue (non-bridge, non-controller) caller is refused, no credit
ROG=$(call creditAndRegister "(principal \"$RPRIN\", \"BTC\", 100000000 : nat, 1 : nat)" --identity "$ROGUE")
assert_contains "rogue creditAndRegister rejected" "$ROG" "Only the Bridge canister may credit deposits"
# Controller read — as the ambient identity this returned a scoped 0 and the
# no-credit assertion passed vacuously; anonymous sees the real balance.
RBAL=$(call getTestBalance "(principal \"$RPRIN\", \"BTC\")" --identity anonymous)
assert_eq "rogue received NO credit" "0" "$(extract_first_nat "$RBAL")"

# (9) amount 0 rejected even for the controller (isolates the amount check past the gate)
ZERO=$(call creditAndRegister "(principal \"$UPRIN\", \"BTC\", 0 : nat, 999 : nat)" --identity anonymous)
assert_contains "amount 0 rejected" "$ZERO" "Amount must be positive"

# ── (10) Asset allowlist — docs/issue-triage-2026-08.md §2.15 ─────
# ASSETS was declared and never used as a membership test, and there is no
# length check anywhere in the Bridge, so an arbitrary Text went straight into
# a permanent map key. Both write paths must now refuse an unknown asset.
BAD=$(bcall claim '("NOT-A-REAL-ASSET")' --identity "$U")
assert_contains "claim refuses an unsupported asset" "$BAD" "Unsupported asset"
BADSIM=$(bcall devSimulateDeposit '("NOT-A-REAL-ASSET", 1000 : nat)' --identity "$U")
assert_contains "devSimulateDeposit refuses an unsupported asset" "$BADSIM" "Unsupported asset"
# A long junk asset is the unbounded-state shape specifically (no length check).
LONGJUNK=$(printf 'A%.0s' $(seq 1 300))
BADLONG=$(bcall claim "(\"$LONGJUNK\")" --identity "$U")
assert_contains "claim refuses a 300-char asset name" "$BADLONG" "Unsupported asset"

# The allowlist the Bridge advertises must be the SAME list it enforces —
# every advertised asset has to get past the membership gate (it then fails on
# the nothing-to-claim check, which proves it passed validation).
SUPPORTED=$(bcall getSupportedAssets '()' --identity "$U")
assert_contains "getSupportedAssets lists ICPUSD" "$SUPPORTED" "ICPUSD"
for a in BTC ETH SOL ICP ICPUSD; do
  R=$(bcall claim "(\"$a\")" --identity "$U")
  assert_not_contains "$a passes the asset gate (advertised == enforced)" "$R" "Unsupported asset"
done

# A no-op claim on a SUPPORTED asset must still report exactly as before —
# the fix reorders the ledger lookup below the rejection, and an absent row is
# definitionally confirmed==claimed==0, so the caller-visible behaviour is
# unchanged. (That the rejection now writes NOTHING is not observable through
# this API — an absent row and a zeroed row both render as zeros in
# getMyDeposits — so it is pinned at source by tests/test_deploy_hygiene.sh's
# "claim never calls the get-or-create ledgerOf" assertion.)
NOOP=$(bcall claim '("ETH")' --identity "$U")
assert_contains "no-op claim still says nothing to claim" "$NOOP" "Nothing to claim"

# ── (11) Posture — §2.15, and the reason the dev hooks stay alive ──
# The Bridge now has a posture of its own instead of outsourcing its safety to
# the DEX's playDepositCap (which is null on #dev AND #production).
BMODE=$(bcall getDeployMode '()' --identity "$U" | tr -d '()" ' | tr -d "\n")
DMODE=$(call getDeployMode '()' | tr -d '()" ' | tr -d "\n")
_ok "postures — DEX #$DMODE / bridge #$BMODE"
# One-directional, not equality: a #dev DEX against a #play Bridge is normal
# on a local replica (the Bridge is stricter, which is safe). What must never
# happen is the Bridge being MORE PERMISSIVE than the DEX it credits — a
# value-bearing DEX with a stub Bridge still answering its unbacked-credit
# hooks is §2.15 wide open.
if [ "$DMODE" = "production" ] && [ "$BMODE" != "production" ]; then
  _fail "DEX is #production but the deployed bridge is #$BMODE — unbacked credit hooks are live"
else
  _ok "deployed bridge is not more permissive than the deployed DEX"
fi

# The posture gate is at #production, NOT at #dev. That is load-bearing:
# devSimulateDeposit is the live #play on-ramp — the Deposit page calls it
# (src/frontend/src/main.js) and the play allowance is consumed through it via
# the DEX's playDepositReserve — so gating it to #dev would delete the only
# on-ramp the committed default posture has.
#
# Assert that directly rather than inferring it from the sections above: the
# hook may legitimately refuse for OTHER reasons (an unverified principal on
# #play, say), but it must never refuse because of the posture.
POSTURE_PROBE=$(bcall devSimulateDeposit '("BTC", 1000 : nat)' --identity "$U")
assert_not_contains "devSimulateDeposit is not posture-refused on #play" \
  "$POSTURE_PROBE" "disabled on #production"
assert_not_contains "devSimulateDeposit is not gated to dev-only" \
  "$POSTURE_PROBE" "dev-only hook"

delid "$U"; delid "$ROGUE"

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_bridge_deposit_claim\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_bridge_deposit_claim ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
