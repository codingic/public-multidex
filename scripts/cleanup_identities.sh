#!/bin/bash
# Prune throwaway test identities from the GLOBAL icp-cli identity store.
#
# Why this matters: `icp network start` — in ANY project on this machine —
# seeds EVERY identity in the global store (1,000,000 ICP + 1000T cycles
# each, minted through the CMC). The CMC refuses to mint more than
# 150,000T cycles per rolling hour, so once the store holds ~150
# identities every fresh local network start fails with:
#   Failed to seed initial balances: ... "More than 150_000_000_000_000_000
#   cycles have been minted in the last 3600 seconds"
#
# Test identities are throwaway plaintext PEMs; every harness recreates
# them on demand (`icp identity new <name> --storage plaintext || true`),
# so deleting them is always safe. Recreation does mean a fresh principal,
# but tests fund their users from scratch each run.
#
# Usage: bash scripts/cleanup_identities.sh [--yes]
#   --yes   skip the confirmation prompt (used by run_tests.sh teardown)
#
# Keeps the named fixtures below (alice is also a local canister
# controller — see cold_start.sh) plus the built-in anonymous identity.
set -u
export PATH="$HOME/.local/bin:$PATH"

KEEP=(anonymous alice bob charlie dave eve swapper buyer taker battery)

YES=false
[ "${1:-}" = "--yes" ] && YES=true

# Current identity names; the default identity's row is marked "* name".
ALL=$(icp identity list 2>/dev/null | sed 's/^\*//' | awk '{print $1}')
if [ -z "$ALL" ]; then
  echo "no identities found (is icp on PATH?)" >&2
  exit 1
fi

DOOMED=()
for name in $ALL; do
  keep=false
  for k in "${KEEP[@]}"; do
    if [ "$name" = "$k" ]; then keep=true; break; fi
  done
  $keep || DOOMED+=("$name")
done

total=$(printf '%s\n' "$ALL" | wc -l | tr -d ' ')
if [ ${#DOOMED[@]} -eq 0 ]; then
  echo "identity store already clean ($total identities)"
  exit 0
fi

echo "deleting ${#DOOMED[@]} of $total identities (keeping: ${KEEP[*]})"
if ! $YES; then
  read -p "Proceed? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "aborted"
    exit 0
  fi
fi

deleted=0
for name in "${DOOMED[@]}"; do
  if echo "y" | icp identity delete "$name" >/dev/null 2>&1; then
    deleted=$((deleted + 1))
  else
    echo "  ! failed to delete: $name" >&2
  fi
done

left=$(icp identity list 2>/dev/null | wc -l | tr -d ' ')
echo "deleted $deleted; $left identities remain"
if [ "$left" -ge 140 ]; then
  echo "WARNING: still >=140 identities — fresh 'icp network start' breaks at ~150 (CMC mint cap)" >&2
  exit 1
fi
