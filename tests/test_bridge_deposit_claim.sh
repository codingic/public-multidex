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
CLAIM=$(bcall claim '("BTC")' --identity "$U")
assert_contains "claim BTC returns ok = 50000000" "$CLAIM" "ok = 50000000"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")")
assert_eq "DEX BTC balance credited" "50000000" "$(extract_first_nat "$BAL")"

# (5) claimed high-water advanced, claimable back to 0
DEP=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "BTC claimed = 50000000" "50000000" "$(extract_nat claimed "$DEP")"
assert_eq "BTC claimable now 0"    "0"        "$(extract_nat claimable "$DEP")"

# (6) idempotent re-claim: rejected, balance unchanged (no double-credit)
CLAIM2=$(bcall claim '("BTC")' --identity "$U")
assert_contains "re-claim rejected (nothing to claim)" "$CLAIM2" "Nothing to claim"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")")
assert_eq "DEX BTC balance unchanged after re-claim" "50000000" "$(extract_first_nat "$BAL")"

# (7) a later confirm+claim credits ONLY the new delta (0.25 BTC)
bcall devSimulateDeposit '("BTC", 25000000 : nat)' --identity "$U" >/dev/null
bcall devConfirmDeposits '()' --identity "$U" >/dev/null
CLAIM3=$(bcall claim '("BTC")' --identity "$U")
assert_contains "second claim ok = 25000000 (delta only)" "$CLAIM3" "ok = 25000000"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")")
assert_eq "DEX BTC balance = 0.75 cumulative" "75000000" "$(extract_first_nat "$BAL")"

# (8) creditAndRegister gating: a rogue (non-bridge, non-controller) caller is refused, no credit
ROG=$(call creditAndRegister "(principal \"$RPRIN\", \"BTC\", 100000000 : nat, 1 : nat)" --identity "$ROGUE")
assert_contains "rogue creditAndRegister rejected" "$ROG" "Only the Bridge canister may credit deposits"
RBAL=$(call getTestBalance "(principal \"$RPRIN\", \"BTC\")")
assert_eq "rogue received NO credit" "0" "$(extract_first_nat "$RBAL")"

# (9) amount 0 rejected even for the controller (isolates the amount check past the gate)
ZERO=$(call creditAndRegister "(principal \"$UPRIN\", \"BTC\", 0 : nat, 999 : nat)" --identity anonymous)
assert_contains "amount 0 rejected" "$ZERO" "Amount must be positive"

delid "$U"; delid "$ROGUE"

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_bridge_deposit_claim\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_bridge_deposit_claim ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
