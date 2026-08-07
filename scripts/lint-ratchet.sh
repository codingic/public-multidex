#!/usr/bin/env bash
# Lint gate for the Motoko backend — run by the pre-push hook (.githooks/pre-push).
#
# Five checks, in order:
#   1. TYPE-CHECK  — `moc --check` must succeed (catches real compile errors),
#                    for src/backend AND for every tests/*.mo.
#
#      HOW THIS GATE WAS DEAD, 2026-08-02. Two independent faults, either of
#      which alone would have been enough:
#        · it ran moc WITHOUT the project's real build flags
#          (--default-persistent-actors --implicit-package=core, see
#          mops.toml), so moc could not resolve the project's own modules and
#          emitted 143 spurious `M0057, unbound variable` errors on main.mo;
#        · its detector was `grep -qE ': error'`, but moc always writes
#          ": type error [Mxxxx]" or ": syntax error [Mxxxx]" — never a bare
#          ": error".
#      So it matched neither the real errors nor its own noise, and printed
#      "✓ type-check: ok" unconditionally. It was confirmed PASSING in a tree
#      where `mops test` reported a failing file.
#      The fix is to use the build flags and to gate on moc's EXIT CODE — the
#      candid step below always did this correctly and is the model.
#
#      The same missing flags silently neutered check 3: without them moc
#      aborts on M0057 before the Nat-subtraction analysis runs, so the
#      "hard zero" M0155 ratchet counted zero because it counted NOTHING.
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
# Every tests/*.mo — the `mops test` suite. Same reason to glob the filesystem.
TEST_FILES=$(find tests -name '*.mo' 2>/dev/null | sort)
fail=0

# The project's REAL build flags — keep in sync with mops.toml
# [canisters.backend].args. (The candid step below already passed these; the
# checks above it did not, which is the whole bug.) The backend's other args
# are output-shaping (--public-metadata, --max-stable-pages) and irrelevant to
# --check.
# Pinned by tests/test_deploy_hygiene.sh §5 — do not rename or inline. The
# same flag set is deliberately REPEATED in scripts/lib/candid.sh
# (mdx_emit_candid); "simplifying" either copy into the other breaks §5.
MOC_FLAGS=(--default-persistent-actors --implicit-package=core)

# 1) Type-check the backend (main.mo transitively checks the whole thing).
# GATE ON THE EXIT CODE, never on a text pattern: moc --check exits 0 when
# there are only warnings and non-zero when there is any error, which is
# precisely the question being asked. Warnings are surfaced as info.
TYPE_OUT=$("$MOC" $SRCS "${MOC_FLAGS[@]}" --check src/backend/main.mo 2>&1)
TYPE_RC=$?
if [ "$TYPE_RC" -ne 0 ]; then
  echo "✗ type-check FAILED — src/backend/main.mo (moc --check exit $TYPE_RC):" >&2
  printf '%s\n' "$TYPE_OUT" | grep -E 'error \[M' | head -20 >&2
  fail=1
else
  WARN_N=$(printf '%s\n' "$TYPE_OUT" | grep -E ': warning \[M' | grep -v 'M0155' \
           | grep -oE 'src/backend/[^:]+:[0-9]+' | grep -v '/oql/' | sort -u | wc -l | tr -d ' ')
  echo "✓ type-check: src/backend ok (${WARN_N} non-M0155 moc warning(s) — run 'mops check' to see them)"
fi

# 1b) Type-check every tests/*.mo, ONE FILE AT A TIME.
#
# Widening the src/backend glob — the obvious fix — would NOT have covered
# this, for two reasons worth stating so nobody "simplifies" it back:
#   · tests/ is never fed to the candid/idl step (check 4), so nothing else in
#     this script ever compiles a test file; and
#   · the M0155 loop (check 3) greps for that ONE warning code, so an M0151 —
#     or a plain type error — in a test file would sail straight through it.
# Per-file is required because there is no root module that imports them all:
# each test is its own program, and a broken one is invisible until `mops
# test` fails in CI, long after the push this hook exists to block.
if [ -n "$TEST_FILES" ]; then
  TEST_FAIL=0
  for f in $TEST_FILES; do
    if ! T_OUT=$("$MOC" $SRCS "${MOC_FLAGS[@]}" --check "$f" 2>&1); then
      echo "✗ type-check FAILED — $f:" >&2
      printf '%s\n' "$T_OUT" | grep -E 'error \[M' | head -10 | sed 's/^/    /' >&2
      TEST_FAIL=$(( TEST_FAIL + 1 ))
    fi
  done
  if [ "$TEST_FAIL" -gt 0 ]; then
    echo "✗ type-check: $TEST_FAIL test file(s) do not compile — 'mops test' cannot pass." >&2
    fail=1
  else
    echo "✓ type-check: tests ok ($(printf '%s\n' "$TEST_FILES" | wc -l | tr -d ' ') file(s))"
  fi
else
  echo "lint-ratchet: no tests/*.mo found — skipping the unit-test type-check." >&2
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
# WITH the build flags, for the same reason as check 1: without them moc
# aborts on unresolved imports (M0057) before it ever runs the Nat-subtraction
# analysis, so this "hard zero gate" was reporting 0 because it was analysing
# nothing. Adding the flags is what makes the count real.
M0155_N=$(for f in $OUR_FILES; do "$MOC" $SRCS "${MOC_FLAGS[@]}" --check "$f" 2>&1 | grep 'M0155'; done \
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
# (mops-first, didc fallback — and "could not check" now FAILS instead of
# silently passing). The full compile (--idl needs codegen, ~40s) only runs
# when checks 1-3 passed, so a broken tree fails fast above.
if [ "$fail" -eq 0 ]; then
  DID_TMP=$(mktemp -d)
  trap 'rm -rf "$DID_TMP"' EXIT
  # Same helper gen-did.sh WRITES with, so "fresh" is byte-equality between one
  # tool's output and itself rather than between two tools that ought to agree.
  # shellcheck source=scripts/lib/candid.sh
  . "$(dirname "$0")/lib/candid.sh"
  if mdx_emit_candid "$DID_TMP/new.did"; then
    mdx_published_body "$DID_TMP/published.did"
    if ! diff -q "$DID_TMP/published.did" "$DID_TMP/new.did" >/dev/null 2>&1; then
      echo "✗ candid: candid/backend.did is STALE — the public surface changed without" >&2
      echo "  regenerating the published contract. Run scripts/gen-did.sh and commit." >&2
      fail=1
    else
      echo "✓ candid: committed contract matches the source"
    fi
    # The subtype gate enforces "additive-only WITHIN a major apiVersion". The
    # qualifier is load-bearing and the gate had no way to express it: a
    # deliberate major bump is EXACTLY a non-subtype change, so without this
    # escape hatch the gate blocks the one operation the stability policy
    # explicitly permits.
    #
    # The hatch is the version itself, not a flag or an env var: bumping the
    # MAJOR of MM_API_VERSION is a visible, reviewable, committed act that the
    # policy already requires for a breaking change. You cannot take the hatch
    # without also making the declaration — which is the point.
    api_major_of() {  # $1 = a git ref, or "" for the working tree
      if [ -z "$1" ]; then grep -oE 'MM_API_VERSION : Text = "[0-9]+' src/backend/main.mo 2>/dev/null
      else git show "$1:src/backend/main.mo" 2>/dev/null | grep -oE 'MM_API_VERSION : Text = "[0-9]+'
      fi | head -1 | grep -oE '[0-9]+$'
    }
    BASE_REF=$(git merge-base HEAD origin/main 2>/dev/null || true)
    NEW_MAJOR=$(api_major_of "")
    BASE_MAJOR=$(api_major_of "$BASE_REF")
    if [ -n "$NEW_MAJOR" ] && [ -n "$BASE_MAJOR" ] && [ "$NEW_MAJOR" != "$BASE_MAJOR" ]; then
      echo "✓ candid: apiVersion major $BASE_MAJOR → $NEW_MAJOR — breaking changes ALLOWED;"
      echo "  subtype gate skipped by declaration. Record it under 'Major bumps so far'"
      echo "  in candid/README.md if you have not already."
    elif [ -n "$BASE_REF" ] \
       && git show "$BASE_REF:candid/backend.did" 2>/dev/null \
          | tail -n +$((MDX_CANDID_HEADER_LINES + 1)) > "$DID_TMP/base.did" \
       && [ -s "$DID_TMP/base.did" ]; then
      # `mops check-candid NEW ORIGINAL` — NEW must be a subtype of ORIGINAL
      # (old clients keep working). Same semantics as `didc check`, but mops is
      # already a hard requirement of this repo, so the gate no longer hinges
      # on didc being installed — it used to print "skipping" and PASS without
      # it, and a breaking-change gate that is off by default is not a gate.
      # (The other half of the old inertness — the pre-push hook not being
      # installed — is a hook/CI problem, not this script's.) didc stays as a
      # fallback for environments that have it but not mops.
      if command -v mops >/dev/null 2>&1; then
        CANDID_CHECK=(mops check-candid)
      elif command -v didc >/dev/null 2>&1; then
        CANDID_CHECK=(didc check)
      else
        CANDID_CHECK=()
      fi
      if [ ${#CANDID_CHECK[@]} -eq 0 ]; then
        echo "✗ candid: neither mops nor didc available — cannot run the breaking-change gate." >&2
        echo "  Refusing to treat 'could not check' as 'compatible'." >&2
        fail=1
      elif "${CANDID_CHECK[@]}" "$DID_TMP/new.did" "$DID_TMP/base.did" > "$DID_TMP/didc.out" 2>&1; then
        echo "✓ candid: backward-compatible with origin/main (${CANDID_CHECK[0]} subtype check)"
      else
        echo "✗ candid: BREAKING interface change vs origin/main — the published API is" >&2
        echo "  additive-only within a major apiVersion (see candid/backend.did header):" >&2
        head -10 "$DID_TMP/didc.out" >&2
        echo "  If this removal is INTENDED, bump the major of MM_API_VERSION and add a" >&2
        echo "  'Major bumps so far' entry in candid/README.md — that is the sanctioned route." >&2
        fail=1
      fi
    else
      echo "✗ candid: could not read origin/main's contract — breaking-change gate did not run." >&2
      echo "  Fetch origin (git fetch origin main) so there is a baseline to compare against." >&2
      fail=1
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
