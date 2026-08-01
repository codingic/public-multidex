#!/usr/bin/env bash
#
# Top up the history (archive) sidecar canister with cycles.
#
# The archive is spawned dynamically by the backend (it is NOT in icp.yaml), so
# this discovers its principal from the backend's
# getCanisterInfo().archiveCanisterId and then `icp canister top-up`s it. The
# backend funds the archive only with ARCHIVE_INITIAL_CYCLES at spawn and has NO
# automatic top-up, so this is the operational tool that keeps the history
# sidecar alive.
#
# Out-of-cycles is non-destructive: when the archive can't be reached the main
# DEX canister BUFFERS the unshipped events in its own stable state
# (getCanisterInfo().journalUnshipped) and the 10s shipper re-ships them once the
# archive is funded again — no history is lost. This script reports that buffered
# count before topping up.
#
# Usage:
#   bash scripts/topup_archive.sh                       # local replica, default amount
#   bash scripts/topup_archive.sh --amount 50t          # custom amount
#   bash scripts/topup_archive.sh -e ic --identity me   # a deployed engine / mainnet
#
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

AMOUNT="20t"
PASS=()   # network/env + identity flags passed straight through to icp
while [ $# -gt 0 ]; do
  case "$1" in
    --amount)          AMOUNT="$2"; shift 2 ;;
    -e|--environment)  PASS+=(-e "$2"); shift 2 ;;
    -n|--network)      PASS+=(-n "$2"); shift 2 ;;
    --identity)        PASS+=(--identity "$2"); shift 2 ;;
    -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

info() { printf '\033[0;36m▶\033[0m %s\n' "$1"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$1"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

command -v icp >/dev/null 2>&1 || die "icp CLI not found — install it (https://cli.internetcomputer.org)."

info "Resolving the archive canister id from the backend…"
INFO=$(icp canister call ${PASS[@]+"${PASS[@]}"} backend getCanisterInfo "()" 2>/dev/null) \
  || die "getCanisterInfo failed — is the backend deployed and the network reachable?"

ARCHIVE_ID=$(printf '%s' "$INFO" | tr '\n' ' ' \
  | grep -oE 'archiveCanisterId = opt "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"') || true
[ -n "$ARCHIVE_ID" ] || die "No archive sidecar spawned yet (archiveCanisterId is null). Generate some history first."

UNSHIPPED=$(printf '%s' "$INFO" | grep -oE 'journalUnshipped = [0-9_]+' | grep -oE '[0-9_]+' | tr -d '_') || true
SHIPPED=$(printf '%s' "$INFO" | grep -oE 'archivedEvents = [0-9_]+' | grep -oE '[0-9_]+' | tr -d '_') || true

info "Archive canister:  $ARCHIVE_ID"
info "Events already in the archive:        ${SHIPPED:-?}"
info "Events buffered in the DEX (to ship): ${UNSHIPPED:-?}"
info "Topping up with $AMOUNT cycles…"

icp canister top-up ${PASS[@]+"${PASS[@]}"} --amount "$AMOUNT" "$ARCHIVE_ID" \
  || die "top-up failed — this network may need a cycles source (e.g. a cycles wallet / ledger)."
ok "Topped up $ARCHIVE_ID with $AMOUNT cycles."

# Best-effort: show the resulting balance (status only works once it's reachable).
BAL=$(icp canister status ${PASS[@]+"${PASS[@]}"} "$ARCHIVE_ID" 2>/dev/null | grep -iE "Balance|cycles" | head -1) || true
[ -n "$BAL" ] && ok "${BAL#"${BAL%%[![:space:]]*}"}"

if [ -n "${UNSHIPPED:-}" ] && [ "${UNSHIPPED:-0}" -gt 0 ]; then
  warn "The DEX is holding ${UNSHIPPED} buffered event(s); the 10s shipper now drains them"
  warn "to the archive (~2000/tick). Watch getCanisterInfo().journalUnshipped fall to 0."
fi
