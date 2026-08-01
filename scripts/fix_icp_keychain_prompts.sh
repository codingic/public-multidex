#!/bin/bash
# Bulk-update macOS keychain ACLs so the icp-cli stops triggering the
# "icp wants to use your confidential information" dialog on every
# invocation.
#
# Why this is needed: icp-cli stores private keys with `--storage keyring`
# by default. Each identity becomes a keychain item under service
# "icp-cli". ACLs are per-item, so clicking "Always Allow" only authorises
# the calling binary for ONE item — the next 200+ items still prompt.
# Worse, the icp npm package symlinks node-script paths that change on
# version bumps, so even the granted ACLs silently invalidate.
#
# What we do: for every icp-cli keychain item, append `unsigned:` to the
# partition list. This pre-authorises any binary (including the
# version-bumped icp script) to read the key without prompting. Keys
# remain encrypted in keychain; only the per-item access policy changes.
#
# Run once, type your login password once. Takes ~10 seconds.

set -u

# Prompt for password (silently) — the security tool needs the LOGIN
# keychain unlock password to mutate ACLs.
read -s -p "macOS login password (will not echo): " PASS
echo
if [ -z "$PASS" ]; then
  echo "Aborted: no password supplied." >&2
  exit 1
fi

# Enumerate every account under service "icp-cli". Parsing
# `security dump-keychain` is fragile, so we use the canonical icp-cli
# identity list. Each icp identity has 1+ keychain items.
LIST=$(icp identity list 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
if [ -z "$LIST" ]; then
  echo "No icp identities found (is icp-cli on PATH?)." >&2
  exit 1
fi

TOTAL=0
DONE=0
SKIPPED=0
for acct in $LIST; do
  TOTAL=$((TOTAL+1))
  # set-generic-password-partition-list operates on one item at a time.
  # -S sets the partition list; apple-tool/apple cover signed Apple
  # tools, unsigned: covers everything else (including the icp.js
  # node script under whatever path it currently lives at).
  if security set-generic-password-partition-list \
       -S 'apple-tool:,apple:,unsigned:' \
       -k "$PASS" \
       -s 'icp-cli' \
       -a "$acct" >/dev/null 2>&1; then
    DONE=$((DONE+1))
  else
    SKIPPED=$((SKIPPED+1))
  fi
done

echo
echo "Updated $DONE / $TOTAL keychain items (skipped $SKIPPED with no matching entry)."
echo "Try running 'icp identity list' or 'icp canister status backend' now —"
echo "the password dialog should no longer appear."
