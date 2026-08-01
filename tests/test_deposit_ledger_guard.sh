#!/bin/bash
# Deposit-ledger integrity: the two guards that keep the Bridge's ledger and
# the DEX's high-water from minting money when they disagree.
#
# ── The slice-credit guard (DEX side) ──
# `creditAndRegister(user, token, amount, seq)` credits `seq - prevSeq`, NOT
# `amount`: `seq` is the Bridge's cumulative confirmed high-water, `amount` its
# delta since its own last acked claim, and after a lost #ok reply the Bridge
# re-sends an OVERLAPPING, larger amount. Deriving the slice from our own
# high-water is what stops that double-minting.
#
# That fix has an inverse. If `creditedSeq` ever loses ground while the
# Bridge's `claimed` does not — a reinstall here, a restore from older state, a
# hand-set seq — then `seq - prevSeq` spans the user's whole history and we
# would mint all of it at once. `amount` is the cross-check: the Bridge never
# sends LESS than the slice it owes, so `creditAmt > amount` can only mean the
# two ledgers have diverged. Refuse rather than mint.
#
# ── The in-flight guards (Bridge side) ──
# `claiming` / `admitting` are set before an `await` and cleared in the
# continuation. They are implicitly STABLE (persistent actor), so an upgrade
# landing mid-call used to leave the flag `true` forever and permanently lock
# that (user, asset) out of claiming. `postupgrade` now clears both: no
# continuation survives an upgrade, so a surviving flag can only be a lie.
#
# What this pins:
#   §1 a consistent (amount, seq) pair PASSES the divergence guard
#   §2 the lost-reply shape (amount > slice) passes — that is the normal case
#      the slice fix was built for, and must not be caught by the inverse guard
#   §3 a divergent pair (slice > amount) is REFUSED, with a diagnostic naming
#      both numbers
#   §4 replay (seq <= prevSeq) is still a silent no-op, not an error
#   §5 the Bridge still serves after an upgrade, and its stable ledger
#      (`admittedUnits`, `ledgers`) survives while the guards do not
#   §6 THE SLICE ITSELF, at the balance: a credit moves the wallet by
#      `seq - applied`, NOT by `amount` — the arithmetic the CRITICAL
#      double-mint fix turns on, which until now had no balance-level
#      assertion anywhere in the suite
#
# NOTE on the two styles here. §1-§4 use an UNBOUND identity, so a credit that
# passes the guard is then refused by the play verification gate — a distinct,
# later error, which is exactly the discriminator those sections need
# ("did it reach the credit path?"). §6 instead BINDS an identity through the
# real normalize→hash→bind hook so credits actually land, and asserts on the
# resulting balance. Error text proves the guard fired; the balance proves the
# arithmetic. Both are needed: a guard that returns the right message while
# crediting the wrong amount would pass §1-§4 and fail §6.
#
# Never calls resetExchange. §6 mints into a throwaway bound identity that is
# deleted afterwards; no existing account is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_deposit_ledger_guard ──"

# `icp identity delete X --yes` is NOT valid ("unexpected argument"), so it
# silently fails and the name survives — a later `identity new` then no-ops and
# the run silently REUSES the previous principal, carrying its balance and its
# email binding. That made §6 pass once and fail on every rerun. Confirm-by-pipe
# is the form that actually deletes.
newid() { echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true
          icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
delid() { echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true; }

newid dlg_user
U=$(icp identity principal --identity dlg_user 2>/dev/null | tail -1)

# Controller-called creditAndRegister, so we drive (amount, seq) directly.
credit() { icp canister call backend creditAndRegister "(principal \"$U\", \"ICP\", $1 : nat, $2 : nat)" --identity anonymous 2>&1; }

DIVERGENCE="Deposit ledger divergence"
VERIFY="verified Google-linked"

# ── §1 consistent pair passes the guard ──
# prevSeq is 0 for a fresh principal, so slice == seq == amount.
R=$(credit 100 100)
assert_not_contains "§1 consistent (amount=slice) is NOT flagged as divergence" "$R" "$DIVERGENCE"
assert_contains "§1 ...it reaches the downstream verification gate" "$R" "$VERIFY"

# ── §2 the lost-reply shape must still pass ──
# amount (500) EXCEEDS the slice (100) — exactly what a re-sent claim looks
# like after a dropped #ok. The slice fix discards the overlap; the inverse
# guard must not mistake this for divergence.
R=$(credit 500 100)
assert_not_contains "§2 lost-reply shape (amount > slice) is not flagged" "$R" "$DIVERGENCE"
assert_contains "§2 ...it too reaches the verification gate" "$R" "$VERIFY"

# ── §3 divergence is refused ──
# The Bridge sends 1 unit while claiming a high-water 1000 ahead of ours: our
# ledger lost ground. Crediting the slice would mint 1000 from a 1-unit claim.
R=$(credit 1 1000)
assert_contains "§3 slice > amount is REFUSED" "$R" "$DIVERGENCE"
assert_not_contains "§3 ...and never reaches the credit path" "$R" "$VERIFY"
# The diagnostic must name both figures — a bare refusal is not actionable.
assert_contains "§3 diagnostic names what the bridge sent" "$R" "bridge sent 1 units"
assert_contains "§3 diagnostic names the implied slice" "$R" "implies 1000"

# A near-miss is still divergence: one unit short is the same class of bug.
R=$(credit 99 100)
assert_contains "§3 off-by-one divergence is refused too" "$R" "$DIVERGENCE"

# ── §4 replay stays a silent no-op ──
# seq <= prevSeq returns #ok BEFORE any mint. prevSeq is still 0 here (every
# call above was refused), so seq 0 is a replay.
R=$(credit 50 0)
assert_contains "§4 replayed seq is a silent no-op" "$R" "ok"
assert_not_contains "§4 ...not reported as divergence" "$R" "$DIVERGENCE"

# ── §5 the Bridge survives an upgrade with its ledger intact ──
# postupgrade clears ONLY the in-flight latches. Deposit bookkeeping is stable
# and must come through untouched.
BEFORE=$(icp canister call bridge getSupportedAssets '()' --query --identity anonymous 2>&1)
icp deploy bridge --identity anonymous >/dev/null 2>&1
AFTER=$(icp canister call bridge getSupportedAssets '()' --query --identity anonymous 2>&1)
assert_eq "§5 bridge serves identically after an upgrade" "$BEFORE" "$AFTER"
# A claim path that was never in flight behaves normally afterwards (the guard
# is clear, so this is the "nothing to claim" answer, not "already in progress").
R=$(icp canister call bridge claim '("ICP")' --identity dlg_user 2>&1)
assert_not_contains "§5 no stranded claim guard after upgrade" "$R" "already in progress"

# ── §6 the slice arithmetic, measured at the wallet ──
# Everything above asserts on ERROR TEXT. This asserts on MONEY, which is
# what the fix is actually about. A verified identity is required for a
# credit to land, so bind one through the real normalize→hash→bind hook.
newid dlg_paid
PAID=$(icp identity principal --identity dlg_paid 2>/dev/null | tail -1)
BIND=$(call setTestEmailBinding "(principal \"$PAID\", \"dlgpaid${RANDOM}$$@gmail.com\")" --identity anonymous)
assert_contains "§6 test identity bound to a verified email" "$BIND" "ok"

# Read the balance AS THE OWNER — getTestBalance is self-or-controller, so an
# unidentified read silently returns 0 and would make every check below pass
# for the wrong reason. (That is exactly what broke test_play_deposit_cap.)
bal() { extract_first_nat "$(call getTestBalance "(principal \"$PAID\", \"ICPUSD\")" --identity dlg_paid)"; }
paycredit() { call creditAndRegister "(principal \"$PAID\", \"ICPUSD\", $1 : nat, $2 : nat)" --identity anonymous; }

assert_eq "§6 fresh wallet starts empty" "0" "$(bal)"

# First claim: 100 units confirmed, none applied → credit 100.
R=$(paycredit 100 100)
assert_contains "§6 first credit accepted" "$R" "ok"
assert_eq "§6 ...wallet moved by the slice (100)" "100" "$(bal)"

# THE DOUBLE-MINT CASE. A lost #ok makes the Bridge re-send an OVERLAPPING,
# larger amount: it reports 500 units since ITS last ack, but the cumulative
# high-water is only 150. The slice is 50. Crediting `amount` would mint 500
# and hand the user 350 units of free money.
R=$(paycredit 500 150)
assert_contains "§6 overlapping re-send accepted" "$R" "ok"
assert_eq "§6 ...credited the 50-unit SLICE, not the 500 reported" "150" "$(bal)"

# Replay of an already-applied high-water is a silent no-op — no second mint.
R=$(paycredit 500 150)
assert_contains "§6 replayed high-water no-ops" "$R" "ok"
assert_eq "§6 ...wallet unchanged by the replay" "150" "$(bal)"

# And the inverse guard still bites on a real balance: refused, nothing minted.
R=$(paycredit 1 900000)
assert_contains "§6 divergent claim refused" "$R" "$DIVERGENCE"
assert_eq "§6 ...and minted nothing" "150" "$(bal)"

delid dlg_paid
delid dlg_user

finish_test "deposit_ledger_guard"
