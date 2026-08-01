#!/usr/bin/env bash
# Lint gate for the Motoko backend — run by the pre-push hook (.githooks/pre-push).
#
# Five checks, in order:
#   1. TYPE-CHECK  — `moc --check` must succeed (catches real compile errors).
#   2. lintoko     — style lints (field punning, compound assignment, naming …)
#                    must be ZERO on our hand-written code. Vendored src/backend/oql
#                    is excluded (third-party). lintoko HAS no autofix, but these are
#                    mechanical: punning `{ x = x }` → `{ x }`, `a := a/10` → `a /= 10`.
#   3. M0155       — "operator may trap for inferred type Nat". Gated at ZERO:
#                    every historical site was audited and resolved 2026-07-09, so any
#                    hit is NEW code. Resolve it, never bump the baseline:
#                      • defensive clamp (zero is a correct answer)  → SafeMath.subOrZero(a, b)
#                      • audited invariant (a >= b guaranteed; a trap = broken invariant,
#                        which we WANT loud) → keep the subtraction but make the type
#                        explicit: `let x : Nat = a - b` or `((a - b) : Nat)`. M0155 only
#                        fires when the result type is INFERRED; the annotation both
#                        silences it and marks the site as deliberate.
#   4. CANDID      — the PUBLISHED contract (candid/backend.did) must be (a) FRESH:
#                    byte-equal to what the pinned moc emits from the current source
#                    (a changed surface without scripts/gen-did.sh = silent API
#                    drift), and (b) when `didc` is installed, a SUBTYPE of the
#                    origin/main merge-base's — the additive-only stability promise,
#                    mechanically enforced instead of reviewed by eye. Without didc
#                    the subtype half skips (install: `cargo install didc`, or a
#                    release binary from github.com/dfinity/candid).
#   5. BADGE SYNC  — the backend badge catalog (getBadgeCatalog — the source of
#                    truth) vs the frontend's BADGE_META shelf table and the docs
#                    page: ids, icons, names, prose, and thresholds-quoted-in-prose
#                    must all agree (scripts/check-badge-sync.mjs).
#
# Baseline history:
#   21 (65b9c31) — initial audit. Unknown to us then, moc was SUPPRESSING all
#      warnings for main.mo itself whenever it imported the old vendored OQL
#      (auth-tokens branch) — main.mo's own M0155 sites never reached the count.
#   45 (2026-07-09) — the OQL re-vendor (16c5200) unmasked 24 PRE-EXISTING
#      main.mo sites (blame: 2026-04→06, none new); audited safe.
#    0 (2026-07-09) — all 45 sites resolved (subOrZero for the longhand clamps,
#      explicit `: Nat` for the invariant-backed ones) so the IDE shows no
#      warnings and any new M0155 stands out. Now a hard zero gate.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

M0155_BASELINE=0

MOC=$(mops toolchain bin moc 2>/dev/null)
LINTOKO=$(mops toolchain bin lintoko 2>/dev/null)
SRCS=$(mops sources 2>/dev/null)

if [ -z "$MOC" ] || [ -z "$SRCS" ]; then
  echo "lint-ratchet: mops/moc unavailable — skipping (run 'mops install'). Push allowed." >&2
  exit 0
fi

# Our hand-written backend — exclude vendored OQL. Glob the filesystem (NOT
# `git ls-files`) so brand-new, not-yet-tracked files are gated too — that is
# exactly the code most likely to introduce a regression.
OUR_FILES=$(find src/backend -name '*.mo' -not -path 'src/backend/oql/*' | sort)
fail=0

# 1) Type-check (main.mo transitively checks the whole backend). moc --check exits
# nonzero on warnings too, so gate on ERRORS only; surface other warnings as info.
TYPE_OUT=$("$MOC" $SRCS --check src/backend/main.mo 2>&1)
if printf '%s\n' "$TYPE_OUT" | grep -qE ': error'; then
  echo "✗ type-check failed (moc --check):" >&2
  printf '%s\n' "$TYPE_OUT" | grep -E ': error' | head -20 >&2
  fail=1
else
  WARN_N=$(printf '%s\n' "$TYPE_OUT" | grep -E ': warning \[M' | grep -v 'M0155' \
           | grep -oE 'src/backend/[^:]+:[0-9]+' | grep -v '/oql/' | sort -u | wc -l | tr -d ' ')
  echo "✓ type-check: ok (${WARN_N} non-M0155 moc warning(s) — run 'mops check' to see them)"
fi

# 2) lintoko — gate at ZERO on our code.
if [ -n "$LINTOKO" ]; then
  LINT_OUT=$("$LINTOKO" -f text $OUR_FILES 2>&1)
  LINT_N=$(printf '%s\n' "$LINT_OUT" | grep -cE '^src/.*Error:' || true)
  if [ "$LINT_N" -gt 0 ]; then
    echo "✗ lintoko: $LINT_N style lint(s) — fix before pushing:" >&2
    printf '%s\n' "$LINT_OUT" | grep -E '^src/.*Error:' >&2
    fail=1
  else
    echo "✓ lintoko: clean"
  fi
else
  echo "lint-ratchet: lintoko not pinned — skipping style gate (mops toolchain use lintoko)." >&2
fi

# 3) M0155 ratchet — count unique sites across our code.
M0155_N=$(for f in $OUR_FILES; do "$MOC" $SRCS --check "$f" 2>&1 | grep 'M0155'; done \
          | grep -oE 'src/backend/[^:]+\.mo:[0-9]+' | grep -v '/oql/' | sort -u | wc -l | tr -d ' ')
if [ "$M0155_N" -gt "$M0155_BASELINE" ]; then
  echo "✗ M0155 (Nat-subtraction may-trap): $M0155_N > baseline $M0155_BASELINE — a new" >&2
  echo "  unguarded subtraction was added. Use SafeMath.subOrZero(a, b) for a defensive" >&2
  echo "  clamp, or confirm a >= b is an invariant; then bump M0155_BASELINE." >&2
  fail=1
elif [ "$M0155_N" -lt "$M0155_BASELINE" ]; then
  echo "✓ M0155: $M0155_N (below baseline — lower M0155_BASELINE to $M0155_N to lock the win in)"
else
  echo "✓ M0155: $M0155_N (at baseline)"
fi

# 4) Published Candid contract — freshness (always) + subtype vs origin/main
# (when didc is installed). The full compile (--idl needs codegen, ~40s) only
# runs when checks 1-3 passed, so a broken tree fails fast above.
if [ "$fail" -eq 0 ]; then
  DID_TMP=$(mktemp -d)
  trap 'rm -rf "$DID_TMP"' EXIT
  if "$MOC" $SRCS --default-persistent-actors --implicit-package=core --idl \
       -o "$DID_TMP/new.wasm" src/backend/main.mo >/dev/null 2>&1 && [ -f "$DID_TMP/new.did" ]; then
    # gen-did.sh prepends a fixed 12-line comment header; strip it for the diff.
    if ! diff <(tail -n +13 candid/backend.did) "$DID_TMP/new.did" >/dev/null 2>&1; then
      echo "✗ candid: candid/backend.did is STALE — the public surface changed without" >&2
      echo "  regenerating the published contract. Run scripts/gen-did.sh and commit." >&2
      fail=1
    else
      echo "✓ candid: committed contract matches the source"
    fi
    BASE_REF=$(git merge-base HEAD origin/main 2>/dev/null || true)
    if command -v didc >/dev/null 2>&1 && [ -n "$BASE_REF" ] \
       && git show "$BASE_REF:candid/backend.did" 2>/dev/null | tail -n +13 > "$DID_TMP/base.did" \
       && [ -s "$DID_TMP/base.did" ]; then
      # didc check NEW OLD — NEW must be a subtype of OLD (old clients keep working).
      if didc check "$DID_TMP/new.did" "$DID_TMP/base.did" > "$DID_TMP/didc.out" 2>&1; then
        echo "✓ candid: backward-compatible with origin/main (didc subtype check)"
      else
        echo "✗ candid: BREAKING interface change vs origin/main — the published API is" >&2
        echo "  additive-only within a major apiVersion (see candid/backend.did header):" >&2
        head -10 "$DID_TMP/didc.out" >&2
        fail=1
      fi
    else
      echo "lint-ratchet: didc not installed — skipping the subtype (breaking-change) gate." >&2
    fi
  else
    echo "✗ candid: could not regenerate the interface (moc --idl failed)" >&2
    fail=1
  fi
else
  echo "lint-ratchet: skipping candid gate — fix the failures above first." >&2
fi

# 5) Badge catalog ↔ frontend sync (source-level, no replica needed).
if command -v node >/dev/null 2>&1; then
  if BADGE_OUT=$(node scripts/check-badge-sync.mjs 2>&1); then
    echo "✓ badge sync: $BADGE_OUT"
  else
    echo "✗ badge sync — the backend catalog (getBadgeCatalog) and its frontend copies drifted:" >&2
    printf '%s\n' "$BADGE_OUT" >&2
    fail=1
  fi
else
  echo "lint-ratchet: node not installed — skipping the badge FE/BE sync gate." >&2
fi

[ "$fail" -eq 0 ] && echo "lint-ratchet: PASS" || echo "lint-ratchet: FAIL — push blocked (override with 'git push --no-verify')." >&2
exit $fail
